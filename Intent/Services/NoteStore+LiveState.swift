import Combine
import Foundation

extension NoteStore {
    // MARK: - Live-state subscription

    func subscribeLiveState(workspaceId: String, generation: Int) async {
        // Initialize note reconciler synchronously before await to eliminate race
        // (any push arriving between subscribe-sent and response-received will have a reconciler ready)
        noteReconciler = DeltaReconciler<Note>(
            getId: { dict in dict["id"] as? String },
            normalize: { dict in Note.parseNote(dict) }
        )

        // Try to subscribe - if server doesn't support it, error response falls back to legacy
        do {
            let result = try await connectionManager.request("note.subscribe", params: [
                "workspaceId": workspaceId,
                "limit": PagedReads.notePageLimit,
                "replaceGroup": "ios-notes-\(workspaceId)"
            ])
            guard generation == liveSubscriptionGeneration, self.workspaceId == workspaceId else {
                if let dict = result as? [String: Any], let subId = dict["subscriptionId"] as? String,
                   connectionManager.connectionState == .connected {
                    _ = try? await connectionManager.request("note.unsubscribe", params: ["subscriptionId": subId])
                }
                return
            }
            if let dict = result as? [String: Any],
               let subId = dict["subscriptionId"] as? String {
                // Unregister old handler if we had one
                if let oldId = liveSubscription.acknowledge(subId) {
                    connectionManager.unregisterSubscriptionHandler(id: oldId)
                }
                // Register handler immediately in same MainActor tick (preserves sync-capture guarantee)
                connectionManager.registerSubscriptionHandler(id: subId) { [weak self] push in
                    self?.handleSubscriptionPush(push)
                }
                AppLog.notes.info("[NoteStore] Subscribed to note.subscribe: \(subId)")
            } else {
                // Response missing subscriptionId - clean up and fall back to legacy
                noteReconciler = nil
                liveSubscription.subscribeFailed()
            }
        } catch {
            guard generation == liveSubscriptionGeneration else { return }
            // Subscribe failed - clean up reconciler and fall back to legacy
            noteReconciler = nil
            liveSubscription.subscribeFailed()
            AppLog.notes.warning("[NoteStore] note.subscribe failed: \(error), falling back to legacy")
        }
    }

    // MARK: - Event subscription

    func startObservingEvents(workspaceId: String? = nil) {
        if let workspaceId {
            self.workspaceId = workspaceId
        }

        // Remove old handler to prevent accumulation on reconnect
        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
        }

        // Register event handler on ConnectionManager
        // (server subscription is handled centrally by ConnectionManager.subscribeToAllEvents)
        eventHandlerId = connectionManager.onEvent { [weak self] method, params in
            Task { @MainActor [weak self] in
                self?.handleEvent(method, params: params)
            }
        }
    }

    /// Pauses live event/push/reconnect observation while cached offscreen in
    /// `WorkspaceDetailStoresCache`, keeping cached notes for read-only mode.
    func suspendObservation() {
        eventRefreshes.cancel()
        snapshotFiller.cancel()
        noteReconciler = nil
        liveSubscriptionGeneration &+= 1
        if let subId = liveSubscription.reset() {
            connectionManager.unregisterSubscriptionHandler(id: subId)
            if connectionManager.connectionState == .connected {
                let connection = connectionManager
                Task { _ = try? await connection.request("note.unsubscribe", params: ["subscriptionId": subId]) }
            }
        }
        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
            eventHandlerId = nil
        }
        connectionObserver = nil
    }

    /// Restores observation and live subscription when the cached workspace reappears.
    func resumeObservation(workspaceId: String) {
        let wasSuspended = connectionObserver == nil
        if connectionObserver == nil {
            observeConnection(dropInitialState: true)
        }
        startObservingEvents(workspaceId: workspaceId)
        if wasSuspended, connectionManager.connectionState == .connected, liveSubscription == .idle {
            let generation = liveSubscriptionGeneration
            Task { [weak self] in
                guard let self, connectionObserver != nil, self.workspaceId == workspaceId,
                      generation == liveSubscriptionGeneration, liveSubscription == .idle else { return }
                await subscribeLiveState(workspaceId: workspaceId, generation: generation)
            }
        }
    }

    private func handleEvent(_ method: String, params: Any) {
        // Handle subscription.push for live-state updates (test injection compatibility)
        if let push = SubscriptionPush.parse(method: method, params: params) {
            handleSubscriptionPush(push)
            return
        }

        guard let event = Self.event(from: params) else { return }
        guard let eventType = event["type"] as? String else { return }

        let eventWorkspaceId = event["workspaceId"] as? String
        guard eventWorkspaceId == workspaceId || eventWorkspaceId == nil else { return }

        switch Self.classify(type: eventType, data: event["data"] as? [String: Any]) {
        case .refetch:
            // Only refetch if not in live mode (avoid double-apply)
            if !liveSubscription.isLive, let workspaceId {
                queueEventRefresh(workspaceId: workspaceId)
            }
            onNoteChanged?()
            if eventType != "note:created" {
                for continuation in noteChangeContinuations.values {
                    continuation.yield()
                }
            }
        case .patchInPlace, .ignore, nil:
            break
        }
    }

    private func queueEventRefresh(workspaceId: String) {
        guard eventRefreshes.invalidate() else { return }
        Task { @MainActor [weak self] in
            guard let self, self.workspaceId == workspaceId else { return }
            while await eventRefreshes.run(
                isCurrent: { [weak self] in self?.workspaceId == workspaceId && self?.liveSubscription.isLive == false },
                pass: { [weak self] _ in await self?.fetchNotes(workspaceId: workspaceId) }
            ) {}
        }
    }

    private func handleSubscriptionPush(_ push: SubscriptionPush) {
        // Only process pushes if we have a reconciler ready
        // (reconciler is initialized synchronously before subscribe request, so any
        // push arriving between subscribe-sent and response-received is safe to process)
        guard let reconciler = noteReconciler else {
            return
        }

        // ConnectionManager now routes pushes by subscriptionId at the transport layer,
        // so this handler only receives pushes for our exact subscriptionId.
        // No per-store gate needed (single source of truth is the router)

        switch push.kind {
        case .snapshot:
            guard let rawItems = push.snapshot else { return }
            liveSubscription.applySnapshot()
            reconciler.applySnapshot(seq: push.seq, rawItems: rawItems)
            AppLog.notes.debug("[NoteStore] Applied snapshot with \(rawItems.count) notes, seq=\(push.seq)")
            if let token = push.nextToken {
                fillSnapshot(reconciler: reconciler, firstToken: token)
            } else {
                snapshotFiller.cancel()
                notes = reconciler.values()
            }

        case .delta:
            guard let delta = push.delta else { return }
            if reconciler.applyDelta(seq: push.seq, delta: delta) {
                // A paged snapshot still filling publishes once complete.
                if !snapshotFiller.isFilling { notes = reconciler.values() }
                AppLog.notes.debug("[NoteStore] Applied delta seq=\(push.seq), added=\(delta.added.count), updated=\(delta.updated.count), removed=\(delta.removedIds.count)")
            } else {
                // Gap detected — resnapshot (guard against storm)
                if liveSubscription.requestResnapshot() {
                    AppLog.notes.warning("[NoteStore] Sequence gap detected at seq=\(push.seq), resubscribing...")
                    Task { await resnapshot() }
                }
            }
        }
    }

    /// Reads the rest of a paged snapshot (§6.9) with `note.list` in the
    /// subscription's projection (full), then publishes the whole list; the
    /// previous list stays visible meanwhile. A walk that gives up shows what
    /// it has unless that would shrink the list, then resubscribes.
    private func fillSnapshot(reconciler: DeltaReconciler<Note>, firstToken: String) {
        guard let workspaceId else { return }
        let source = PagedReads.PageSource(field: "notes") { [connectionManager] token in
            try await connectionManager.request("note.list", params: [
                "workspaceId": workspaceId, "limit": PagedReads.notePageLimit, "nextToken": token
            ])
        }
        snapshotFiller.start(reconciler, from: firstToken, source: source, owner: .init(
            isCurrent: { [weak self] in self?.noteReconciler === reconciler && self?.workspaceId == workspaceId },
            publish: { [weak self] complete in
                guard let self, complete || reconciler.values().count >= notes.count else { return }
                notes = reconciler.values()
            },
            resubscribe: { [weak self] in
                guard let self, !liveSubscription.isResnapshotting else { return }
                await resnapshot()
            }
        ))
    }

    private func resnapshot() async {
        let generation = liveSubscriptionGeneration
        liveSubscription.beginResnapshot()
        defer {
            if generation == liveSubscriptionGeneration {
                liveSubscription.endResnapshot()
            }
        }

        noteReconciler?.reset()
        snapshotFiller.cancel()

        if let subId = liveSubscription.id {
            // Unregister handler before unsubscribing
            connectionManager.unregisterSubscriptionHandler(id: subId)
            do {
                _ = try await connectionManager.request("note.unsubscribe", params: [
                    "subscriptionId": subId
                ])
            } catch {
                AppLog.notes.error("[NoteStore] note.unsubscribe failed: \(error)")
            }
        }

        guard generation == liveSubscriptionGeneration else { return }
        liveSubscription.clearId()

        if let workspaceId {
            await subscribeLiveState(workspaceId: workspaceId, generation: generation)
            guard generation == liveSubscriptionGeneration, self.workspaceId == workspaceId else { return }
            // Baseline refetch to bridge the gap during resnapshot
            await fetchNotes(workspaceId: workspaceId)
        }
    }
}
