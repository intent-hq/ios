import Foundation

extension WorkspaceStatusStore {
    /// Duplicate callers await the same ACK and read. Empty success and errors
    /// are both cached for this activation; errors retry explicitly or on reconnect.
    func load(workspaceId: String, refresh: Bool = false) async {
        guard let bucket = buckets[workspaceId], !bucket.consumers.isEmpty else { return }
        if let task = bucket.loadTask { await task.value; return }
        guard refresh || !bucket.attempted else { return }
        bucket.attempted = true
        bucket.isLoading = true
        let generation = bucket.generation
        let task = Task { [weak self] in
            guard let self, owns(bucket, workspaceId: workspaceId, generation: generation) else { return }
            let ready = await ensureFeed(workspaceId: workspaceId, retry: refresh)
            guard owns(bucket, workspaceId: workspaceId, generation: generation) else { return }
            if ready {
                await read(bucket, workspaceId: workspaceId, generation: generation)
            } else {
                bucket.error = feeds[feedKey(workspaceId)]?.error ?? "Status subscription failed."
                bucket.isStale = true
            }
            guard owns(bucket, workspaceId: workspaceId, generation: generation) else { return }
            bucket.isLoading = false
            bucket.loadTask = nil
        }
        bucket.loadTask = task
        await task.value
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
            if let task = feed.task { return await task.value }
            if !retry { return false }
        }
        installHandler()
        let feed = Feed()
        feeds[key] = feed
        let epoch = connectionEpoch
        let task = Task { [weak self] in
            guard let self, feeds[key] === feed, epoch == connectionEpoch else { return false }
            return await subscribe(feed, key: key, workspaceId: workspaceId, epoch: epoch)
        }
        feed.task = task
        return await task.value
    }

    private func subscribe(_ feed: Feed, key: String, workspaceId: String, epoch: Int) async -> Bool {
        var params: [String: Any] = ["eventTypes": ["\(family):*"], "replaceGroup": replaceGroup]
        if !globalFeed {
            params["workspaceId"] = workspaceId
            params["replaceGroup"] = "\(replaceGroup)-\(workspaceId)"
        }
        do {
            let result = try await connection.request("events.subscribe", params: params)
            let id = (result as? [String: Any])?["subscriptionId"] as? String
            guard feeds[key] === feed, epoch == connectionEpoch else {
                if let id, epoch == connectionEpoch { Self.releaseRemote(id, connection: connection) }
                return false
            }
            guard let id, !id.isEmpty else { throw StatusReadError.malformed }
            feed.id = id
            feed.task = nil
            return true
        } catch {
            guard feeds[key] === feed, epoch == connectionEpoch else { return false }
            feed.error = error.localizedDescription
            feed.task = nil
            return false
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
        let data = event["data"] as? [String: Any] ?? [:]
        guard let workspaceId = data["workspaceId"] as? String ?? event["workspaceId"] as? String,
              let bucket = buckets[workspaceId], !bucket.consumers.isEmpty,
              let feed = feeds[feedKey(workspaceId)] else { return }
        if let id = feed.id, let received = envelope["subscriptionId"] as? String, id != received { return }
        applyEvent(type, data: data, bucket: bucket, workspaceId: workspaceId, feedReady: feed.id != nil)
    }

    private func applyEvent(_ type: String, data: [String: Any], bucket: Bucket, workspaceId: String, feedReady: Bool) {
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
    static func releaseRemote(_ id: String, connection: any ConnectionManagerRouting) -> Task<Void, Never> {
        Task { @MainActor in
            _ = try? await connection.request("events.unsubscribe", params: ["subscriptionId": id])
        }
    }
}

private enum StatusReadError: LocalizedError {
    case malformed

    var errorDescription: String? { "Invalid status response. Retry to update it." }
}
