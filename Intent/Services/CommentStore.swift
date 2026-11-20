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

    @ObservationIgnored private var liveSubscription = LiveSubscription.idle
    @ObservationIgnored private var liveSubscriptionGeneration = 0
    @ObservationIgnored private var commentReconciler: DeltaReconciler<CommentThread>?
    @ObservationIgnored let snapshotFiller = PagedSnapshotFiller()

    init(connectionManager: ConnectionManagerRouting = ConnectionManager.shared) {
        self.connectionManager = connectionManager
        observeConnection()
    }

    /// Test-only initializer that skips connection observation
    init(forTesting _: Bool) {
        self.connectionManager = ConnectionManager.shared
    }

    isolated deinit {
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
        liveSubscriptionGeneration &+= 1
        if let oldId = liveSubscription.reset() {
            connectionManager.unregisterSubscriptionHandler(id: oldId)
        }
        commentReconciler = nil
        snapshotFiller.cancel()

        if let wsId = workspaceId, let noteId = currentNoteId {
            await subscribeToNote(workspaceId: wsId, noteId: noteId)
        }
    }

    // MARK: - Public API

    func subscribeToNote(workspaceId: String, noteId: String) async {
        if currentNoteId != noteId {
            liveSubscriptionGeneration &+= 1
            if let prevSubId = liveSubscription.reset() {
                connectionManager.unregisterSubscriptionHandler(id: prevSubId)
                await unsubscribe(subscriptionId: prevSubId)
            }
        }

        self.workspaceId = workspaceId
        self.currentNoteId = noteId

        if eventHandlerId == nil {
            eventHandlerId = connectionManager.onEvent { [weak self] method, params in
                Task { @MainActor in
                    self?.handleEvent(method, params: params)
                }
            }
        }

        await subscribeLiveState(workspaceId: workspaceId, noteId: noteId, generation: liveSubscriptionGeneration)
    }

    func unsubscribeFromCurrentNote() async {
        liveSubscriptionGeneration &+= 1
        if let subId = liveSubscription.reset() {
            connectionManager.unregisterSubscriptionHandler(id: subId)
            await unsubscribe(subscriptionId: subId)
        }
        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
            eventHandlerId = nil
        }
        commentReconciler = nil
        snapshotFiller.cancel()
        currentNoteId = nil
        threads = []
    }

    // MARK: - Subscription

    private func subscribeLiveState(workspaceId: String, noteId: String, generation: Int) async {
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
            guard generation == liveSubscriptionGeneration, currentNoteId == noteId else {
                if let dict = result as? [String: Any], let subId = dict["subscriptionId"] as? String {
                    await unsubscribe(subscriptionId: subId)
                }
                return
            }
            if let dict = result as? [String: Any],
               let subId = dict["subscriptionId"] as? String {
                if let oldId = liveSubscription.acknowledge(subId) {
                    connectionManager.unregisterSubscriptionHandler(id: oldId)
                }
                connectionManager.registerSubscriptionHandler(id: subId) { [weak self] push in
                    self?.handleSubscriptionPush(push)
                }
                AppLog.comments.debug("[CommentStore] Subscribed to comment.subscribe for note \(noteId): \(subId)")
            } else {
                commentReconciler = nil
                liveSubscription.subscribeFailed()
            }
        } catch {
            guard generation == liveSubscriptionGeneration else { return }
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

        if !liveSubscription.isLive {
            // Handle legacy comment:* events if needed
        }
    }

    private func handleSubscriptionPush(_ push: SubscriptionPush) {
        guard let reconciler = commentReconciler else {
            return
        }

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
                if !snapshotFiller.isFilling { threads = reconciler.values() }
                AppLog.comments.debug("[CommentStore] Applied delta seq=\(push.seq), added=\(delta.added.count), updated=\(delta.updated.count), removed=\(delta.removedIds.count)")
            } else {
                if liveSubscription.requestResnapshot() {
                    AppLog.comments.warning("[CommentStore] Sequence gap detected at seq=\(push.seq), resubscribing...")
                    Task { await resnapshot() }
                }
            }
        }
    }

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
        let generation = liveSubscriptionGeneration
        liveSubscription.beginResnapshot()
        defer {
            if generation == liveSubscriptionGeneration {
                liveSubscription.endResnapshot()
            }
        }

        commentReconciler?.reset()
        snapshotFiller.cancel()

        if let subId = liveSubscription.id {
            connectionManager.unregisterSubscriptionHandler(id: subId)
            await unsubscribe(subscriptionId: subId)
        }

        guard generation == liveSubscriptionGeneration else { return }
        liveSubscription.clearId()

        if let wsId = workspaceId, let noteId = currentNoteId {
            await subscribeLiveState(workspaceId: wsId, noteId: noteId, generation: generation)
        }
    }
}
