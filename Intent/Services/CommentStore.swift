import Combine
import Foundation
import Observation

@MainActor
@Observable class CommentStore {
    var threads: [CommentThread] = []
    var isLoading = false

    @ObservationIgnored private var workspaceId: String?
    @ObservationIgnored private var currentNoteId: String?
    @ObservationIgnored private var connectionObserver: AnyCancellable?
    @ObservationIgnored private var eventHandlerId: UUID?
    @ObservationIgnored private let connectionManager: ConnectionManagerRouting

    // Live-state subscription tracking
    @ObservationIgnored private var liveSubscription = LiveSubscription.idle
    @ObservationIgnored private var commentReconciler: DeltaReconciler<CommentThread>?
    /// Reads the rest of a paged `comment.subscribe` snapshot (protocol §6.9).
    @ObservationIgnored let snapshotFiller = PagedSnapshotFiller()

    init(connectionManager: ConnectionManagerRouting = ConnectionManager.shared) {
        self.connectionManager = connectionManager
        observeConnection()
    }

    /// Test-only initializer that skips connection observation
    init(forTesting _: Bool) {
        self.connectionManager = ConnectionManager.shared
        // No connection observation for unit tests
    }

    isolated deinit {
        // Remove handlers directly while deinit is isolated to MainActor.
        guard eventHandlerId != nil || liveSubscription.id != nil else { return }
        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
        }
        if let subscriptionId = liveSubscription.id {
            connectionManager.unregisterSubscriptionHandler(id: subscriptionId)
        }
    }

    /// Test-only helper to set reconciler for race condition testing
    func setTestReconciler(_ reconciler: DeltaReconciler<CommentThread>) async {
        await MainActor.run {
            commentReconciler = reconciler
        }
    }

    // MARK: - Connection observation

    private func observeConnection() {
        connectionObserver = connectionManager.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state == .connected {
                    Task { await self?.onConnected() }
                }
            }
    }

    private func onConnected() async {
        // Reset live-state tracking on new connection. Unregister the old
        // handler if reconnecting (defensive: subscription is invalid after disconnect)
        if let oldId = liveSubscription.reset() {
            connectionManager.unregisterSubscriptionHandler(id: oldId)
        }
        commentReconciler = nil
        snapshotFiller.cancel()

        // Resubscribe if we were viewing a note
        if let wsId = workspaceId, let noteId = currentNoteId {
            await subscribeToNote(workspaceId: wsId, noteId: noteId)
        }
    }

    // MARK: - Public API

    func subscribeToNote(workspaceId: String, noteId: String) async {
        // Unsubscribe from previous note if different
        if let prevSubId = liveSubscription.id, currentNoteId != noteId {
            connectionManager.unregisterSubscriptionHandler(id: prevSubId)
            await unsubscribe(subscriptionId: prevSubId)
        }

        self.workspaceId = workspaceId
        self.currentNoteId = noteId

        // Register event handler if not already registered
        if eventHandlerId == nil {
            eventHandlerId = connectionManager.onEvent { [weak self] method, params in
                Task { @MainActor in
                    self?.handleEvent(method, params: params)
                }
            }
        }

        await subscribeLiveState(workspaceId: workspaceId, noteId: noteId)
    }

    func unsubscribeFromCurrentNote() async {
        if let subId = liveSubscription.id {
            connectionManager.unregisterSubscriptionHandler(id: subId)
            await unsubscribe(subscriptionId: subId)
        }
        // Remove event handler to prevent leak
        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
            eventHandlerId = nil
        }
        liveSubscription.reset()
        commentReconciler = nil
        snapshotFiller.cancel()
        currentNoteId = nil
        threads = []
    }

    // MARK: - Subscription

    private func subscribeLiveState(workspaceId: String, noteId: String) async {
        // Initialize comment reconciler SYNCHRONOUSLY before RPC
        commentReconciler = DeltaReconciler<CommentThread>(
            getId: { dict in dict["threadId"] as? String },
            normalize: { dict in CommentThread.parseThread(dict) }
        )

        do {
            let result = try await connectionManager.request("comment.subscribe", params: [
                "workspaceId": workspaceId,
                "noteId": noteId,
                "limit": PagedReads.commentPageLimit,
                "replaceGroup": "ios-comments-\(noteId)"
            ])
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
                AppLog.comments.debug("[CommentStore] Subscribed to comment.subscribe for note \(noteId): \(subId)")
            } else {
                // Response missing subscriptionId - clean up and fall back to legacy
                commentReconciler = nil
                liveSubscription.subscribeFailed()
            }
        } catch {
            // Subscribe failed - clean up reconciler and fall back to legacy
            commentReconciler = nil
            liveSubscription.subscribeFailed()
            AppLog.comments.error("[CommentStore] comment.subscribe failed: \(error), falling back to legacy")
        }
    }

    private func unsubscribe(subscriptionId: String) async {
        do {
            _ = try await connectionManager.request("comment.unsubscribe", params: [
                "subscriptionId": subscriptionId
            ])
            AppLog.comments.debug("[CommentStore] Unsubscribed: \(subscriptionId)")
        } catch {
            AppLog.comments.error("[CommentStore] comment.unsubscribe failed: \(error)")
        }
    }

    // MARK: - Event handling

    func handleEvent(_ method: String, params: Any) {
        // Handle subscription.push for live-state updates (test injection compatibility)
        if let push = SubscriptionPush.parse(method: method, params: params) {
            handleSubscriptionPush(push)
            return
        }

        // Legacy event handling (only if not live)
        if !liveSubscription.isLive {
            // Handle legacy comment:* events if needed
        }
    }

    private func handleSubscriptionPush(_ push: SubscriptionPush) {
        // Only process pushes if we have a reconciler ready
        // (reconciler is initialized synchronously before subscribe request, so any
        // push arriving between subscribe-sent and response-received is safe to process)
        guard let reconciler = commentReconciler else {
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
            AppLog.comments.debug("[CommentStore] Applied snapshot with \(rawItems.count) threads, seq=\(push.seq)")
            if let token = push.nextToken {
                fillSnapshot(reconciler: reconciler, firstToken: token)
            } else {
                snapshotFiller.cancel()
                threads = reconciler.values()
            }

        case .delta:
            guard let delta = push.delta else { return }
            if reconciler.applyDelta(seq: push.seq, delta: delta) {
                // A paged snapshot still filling publishes once complete.
                if !snapshotFiller.isFilling { threads = reconciler.values() }
                AppLog.comments.debug("[CommentStore] Applied delta seq=\(push.seq), added=\(delta.added.count), updated=\(delta.updated.count), removed=\(delta.removedIds.count)")
            } else {
                // Gap detected — resnapshot (guard against storm)
                if liveSubscription.requestResnapshot() {
                    AppLog.comments.warning("[CommentStore] Sequence gap detected at seq=\(push.seq), resubscribing...")
                    Task { await resnapshot() }
                }
            }
        }
    }

    /// Reads the rest of a paged snapshot (§6.9) with `comment.list`, then
    /// publishes every thread. Only the summary fields are read here; they
    /// describe the whole thread even when the daemon trims a large thread's
    /// `comments` (`commentsTruncated`), so no `comment.getThread` is needed.
    /// A walk that gives up shows what it has unless that would shrink the
    /// list, then resubscribes.
    private func fillSnapshot(reconciler: DeltaReconciler<CommentThread>, firstToken: String) {
        guard let workspaceId, let noteId = currentNoteId else { return }
        let source = PagedReads.PageSource(field: "threads") { [connectionManager] token in
            try await connectionManager.request("comment.list", params: [
                "workspaceId": workspaceId,
                "noteId": noteId,
                "includeComments": true,
                "limit": PagedReads.commentPageLimit,
                "nextToken": token
            ])
        }
        snapshotFiller.start(reconciler, from: firstToken, source: source, owner: .init(
            isCurrent: { [weak self] in self?.commentReconciler === reconciler && self?.currentNoteId == noteId },
            publish: { [weak self] complete in
                guard let self, complete || reconciler.values().count >= threads.count else { return }
                threads = reconciler.values()
            },
            resubscribe: { [weak self] in
                guard let self, !liveSubscription.isResnapshotting else { return }
                await resnapshot()
            }
        ))
    }

    private func resnapshot() async {
        liveSubscription.beginResnapshot()
        defer { liveSubscription.endResnapshot() }

        commentReconciler?.reset()
        snapshotFiller.cancel()

        if let subId = liveSubscription.id {
            // Unregister handler before unsubscribing
            connectionManager.unregisterSubscriptionHandler(id: subId)
            await unsubscribe(subscriptionId: subId)
        }

        liveSubscription.clearId()

        // Re-subscribe
        if let wsId = workspaceId, let noteId = currentNoteId {
            await subscribeLiveState(workspaceId: wsId, noteId: noteId)
        }
    }
}
