import Foundation

extension WorkspaceStatusStore {
    /// Duplicate callers await the same ACK and read. Empty success and errors
    /// are both cached for this activation; errors retry explicitly or on reconnect.
    func load(workspaceId: String, refresh: Bool = false, nextPage: Bool = false) async {
        guard let bucket = loadableBucket(workspaceId: workspaceId) else { return }
        if let completion = bucket.loadCompletion { await completion.wait(cancelledValue: ()); return }
        guard refresh || nextPage || !bucket.attempted else { return }
        guard !nextPage || bucket.nextCursor != nil else { return }
        if pageAdapter != nil { bucket.tombstones = [:] }
        bucket.recoveryExhausted = false
        bucket.accessBlocked = false
        bucket.attempted = true
        bucket.isLoading = true
        let generation = bucket.generation
        let completion = WorkspaceStatusWaiters<Void>()
        bucket.loadCompletion = completion
        let task = Task { [weak self] in
            defer { completion.finish(()) }
            guard let self, owns(bucket, workspaceId: workspaceId, generation: generation) else { return }
            let ready = await ensureFeed(workspaceId: workspaceId, retry: refresh)
            guard !Task.isCancelled, owns(bucket, workspaceId: workspaceId, generation: generation) else { return }
            if ready {
                if pageAdapter != nil {
                    await readPage(bucket, workspaceId: workspaceId, generation: generation, nextPage: nextPage)
                } else {
                    await read(bucket, workspaceId: workspaceId, generation: generation)
                }
            } else {
                bucket.error = feeds[feedKey(workspaceId)]?.error ?? "Status subscription failed."
                bucket.isStale = true
                bucket.recoveryExhausted = pageAdapter != nil
            }
            guard owns(bucket, workspaceId: workspaceId, generation: generation) else { return }
            bucket.isLoading = false
            bucket.loadTask = nil
            bucket.loadCompletion = nil
        }
        bucket.loadTask = task
        await completion.wait(cancelledValue: ())
    }

    private func loadableBucket(workspaceId: String) -> Bucket? {
        guard pageAdapter?.canLoad() != false, !Task.isCancelled,
              let bucket = buckets[workspaceId], !bucket.consumers.isEmpty else { return nil }
        return bucket
    }

    private func read(_ bucket: Bucket, workspaceId: String, generation: Int) async {
        // At most one follow-up for incomplete events during a read. Complete
        // events replay over the seed directly, without an extra list request.
        for attempt in 0..<2 {
            bucket.events = []
            bucket.recoveryIDs = []
            do {
                let result = try await connection.request("\(family).list", params: ["workspaceId": workspaceId])
                guard owns(bucket, workspaceId: workspaceId, generation: generation) else { return }
                guard let raw = (result as? [String: Any])?[listKey] as? [[String: Any]] else {
                    throw StatusReadError.malformed
                }
                var rows = raw.compactMap(parse)
                guard rows.count == raw.count else { throw StatusReadError.malformed }
                var needsRefetch = false
                for (type, data) in bucket.events {
                    let result = fold(rows, type, data)
                    rows = result.rows
                    needsRefetch = needsRefetch || result.needsRefetch
                }
                bucket.rows = rows
                bucket.events = []
                bucket.isStale = needsRefetch
                bucket.error = needsRefetch ? "Status changed during refresh. Retry to update it." : nil
                if !needsRefetch || attempt == 1 { return }
            } catch {
                guard owns(bucket, workspaceId: workspaceId, generation: generation) else { return }
                bucket.error = error.localizedDescription
                bucket.isStale = true
                bucket.events = []
                return
            }
        }
    }

    func ensureFeed(workspaceId: String, retry: Bool) async -> Bool {
        let key = feedKey(workspaceId)
        if let feed = feeds[key] {
            if feed.id != nil { return true }
            if feed.task != nil { return await feed.completion.wait(cancelledValue: false) }
            if !retry { return false }
        }
        installHandler()
        let feed = Feed(epoch: connectionEpoch)
        feeds[key] = feed
        startFeed(feed, key: key, workspaceId: workspaceId)
        return await feed.completion.wait(cancelledValue: false)
    }

    private func startFeed(_ feed: Feed, key: String, workspaceId: String) {
        let epoch = feed.epoch
        var params: [String: Any] = ["eventTypes": ["\(family):*"], "replaceGroup": replaceGroup]
        if !globalFeed {
            params["workspaceId"] = workspaceId
            params["replaceGroup"] = "\(replaceGroup)-\(workspaceId)"
        }
        // Only the request and its connection provenance survive an orphaned
        // ACK. Never hold the status store alive while waiting for that reply.
        let connection = self.connection
        let lifetime = connectionLifetime
        feed.task = Task { [weak self] in
            defer {
                feed.task = nil
                feed.completion.finish(false)
            }
            guard self?.feeds[key] === feed, epoch == lifetime.epoch else { return }
            do {
                let result = try await connection.request("events.subscribe", params: params)
                let id = (result as? [String: Any])?["subscriptionId"] as? String
                guard self?.feeds[key] === feed, epoch == lifetime.epoch else {
                    if let id { Self.releaseRemote(id, connection: connection, lifetime: lifetime, epoch: feed.epoch) }
                    return
                }
                guard let id, !id.isEmpty else { throw StatusReadError.malformed }
                feed.id = id
                feed.completion.finish(true)
            } catch {
                guard self?.feeds[key] === feed, epoch == lifetime.epoch else { return }
                feed.error = error.localizedDescription
                self?.pageAdapter?.didFail(error, workspaceId)
            }
        }
    }

    private func installHandler() {
        guard eventHandlerId == nil else { return }
        let generation = handlerGeneration
        eventHandlerId = connection.onEvent { [weak self] _, params in
            Task { @MainActor [weak self] in
                guard let self, handlerGeneration == generation else { return }
                handleEvent(params)
            }
        }
    }

    func handleEvent(_ params: Any) {
        guard let envelope = params as? [String: Any] else { return }
        let event = envelope["event"] as? [String: Any] ?? envelope
        guard let type = event["type"] as? String, type.hasPrefix("\(family):") else { return }
        var data = event["data"] as? [String: Any] ?? [:]
        guard let workspaceId = data["workspaceId"] as? String ?? event["workspaceId"] as? String,
              let bucket = buckets[workspaceId], !bucket.consumers.isEmpty,
              let feed = feeds[feedKey(workspaceId)] else { return }
        if let id = feed.id, let received = envelope["subscriptionId"] as? String, id != received { return }
        if let adapter = pageAdapter {
            guard adapter.canLoad(), !bucket.accessBlocked else { return }
            if let outerWorkspace = event["workspaceId"] as? String,
               !outerWorkspace.utf8.elementsEqual(workspaceId.utf8) { return }
            guard let normalized = try? adapter.normalizeEvent(type, data, workspaceId) else {
                recoverPage(bucket, workspaceId: workspaceId)
                return
            }
            data = normalized
        }
        applyEvent(type, data: data, bucket: bucket, workspaceId: workspaceId, feedReady: feed.id != nil)
    }

    private func applyEvent(_ type: String, data: [String: Any], bucket: Bucket, workspaceId: String, feedReady: Bool) {
        if pageAdapter != nil {
            applyPageEvent(type, data: data, bucket: bucket, workspaceId: workspaceId, feedReady: feedReady)
            return
        }
        // A terminal removal resolves earlier incomplete updates for that row,
        // including updates queued for reconciliation but not yet read.
        if removalEvents.contains(type), let id = data[eventIDKey] as? String {
            bucket.recoveryIDs.remove(id)
            bucket.events.removeAll { $0.1[eventIDKey] as? String == id }
        }
        let result = fold(bucket.rows, type, data)
        bucket.rows = result.rows
        if bucket.isLoading {
            bucket.events.append((type, data))
        } else if result.needsRefetch, feedReady, let id = data[eventIDKey] as? String {
            bucket.recoveryIDs.insert(id)
            let generation = bucket.generation
            Task {
                guard owns(bucket, workspaceId: workspaceId, generation: generation), !bucket.recoveryIDs.isEmpty else { return }
                await load(workspaceId: workspaceId, refresh: true)
            }
        }
    }

    @discardableResult
    func releaseRemote(_ feed: Feed) -> Task<Void, Never>? {
        feed.id.map { Self.releaseRemote($0, connection: connection, lifetime: connectionLifetime, epoch: feed.epoch) }
    }

    @discardableResult
    static func releaseRemote(
        _ id: String,
        connection: any ConnectionManagerRouting,
        lifetime: ConnectionLifetime,
        epoch: Int
    ) -> Task<Void, Never> {
        Task { @MainActor in
            guard lifetime.epoch == epoch else { return }
            _ = try? await connection.request("events.unsubscribe", params: ["subscriptionId": id])
        }
    }
}

private enum StatusReadError: LocalizedError {
    case malformed

    var errorDescription: String? { "Invalid status response. Retry to update it." }
}
