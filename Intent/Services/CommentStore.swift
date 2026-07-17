import Foundation
import Combine

@MainActor
class CommentStore: ObservableObject {
    @Published var threads: [CommentThread] = []
    @Published var isLoading = false
    
    private var workspaceId: String?
    private var currentNoteId: String?
    private var connectionObserver: AnyCancellable?
    private var eventHandlerId: UUID?
    
    // Live-state subscription tracking
    private var commentSubscriptionId: String?
    private var commentReconciler: DeltaReconciler<CommentThread>?
    private var commentLive = false
    private var resnapshotInProgress = false
    
    init() {
        observeConnection()
    }
    
    /// Test-only initializer that skips connection observation
    init(forTesting: Bool) {
        // No connection observation for unit tests
    }
    
    /// Test-only helper to set reconciler for race condition testing
    func setTestReconciler(_ reconciler: DeltaReconciler<CommentThread>) async {
        await MainActor.run {
            commentReconciler = reconciler
        }
    }
    
    // MARK: - Connection observation
    
    private func observeConnection() {
        connectionObserver = ConnectionManager.shared.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state == .connected {
                    Task { await self?.onConnected() }
                }
            }
    }
    
    private func onConnected() async {
        // Reset live-state tracking on new connection
        commentLive = false
        commentSubscriptionId = nil
        commentReconciler = nil
        resnapshotInProgress = false
        
        // Resubscribe if we were viewing a note
        if let wsId = workspaceId, let noteId = currentNoteId {
            await subscribeToNote(workspaceId: wsId, noteId: noteId)
        }
    }
    
    // MARK: - Public API
    
    func subscribeToNote(workspaceId: String, noteId: String) async {
        // Unsubscribe from previous note if different
        if let prevSubId = commentSubscriptionId, currentNoteId != noteId {
            await unsubscribe(subscriptionId: prevSubId)
        }
        
        self.workspaceId = workspaceId
        self.currentNoteId = noteId
        
        // Register event handler if not already registered
        if eventHandlerId == nil {
            eventHandlerId = ConnectionManager.shared.onEvent { [weak self] method, params in
                Task { @MainActor in
                    self?.handleEvent(method, params: params)
                }
            }
        }
        
        await subscribeLiveState(workspaceId: workspaceId, noteId: noteId)
    }
    
    func unsubscribeFromCurrentNote() async {
        if let subId = commentSubscriptionId {
            await unsubscribe(subscriptionId: subId)
        }
        // Remove event handler to prevent leak
        if let handlerId = eventHandlerId {
            ConnectionManager.shared.removeEventHandler(id: handlerId)
            eventHandlerId = nil
        }
        commentSubscriptionId = nil
        commentReconciler = nil
        commentLive = false
        resnapshotInProgress = false
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
            let result = try await ConnectionManager.shared.request("comment.subscribe", params: [
                "workspaceId": workspaceId,
                "noteId": noteId,
                "replaceGroup": "ios-comments-\(noteId)"
            ])
            if let dict = result as? [String: Any],
               let subId = dict["subscriptionId"] as? String {
                commentSubscriptionId = subId
                print("[CommentStore] Subscribed to comment.subscribe for note \(noteId): \(subId)")
            } else {
                // Response missing subscriptionId - clean up and fall back to legacy
                commentReconciler = nil
                commentSubscriptionId = nil
                commentLive = false
            }
        } catch {
            // Subscribe failed - clean up reconciler and fall back to legacy
            commentReconciler = nil
            commentSubscriptionId = nil
            commentLive = false
            print("[CommentStore] comment.subscribe failed: \(error), falling back to legacy")
        }
    }
    
    private func unsubscribe(subscriptionId: String) async {
        do {
            let _ = try await ConnectionManager.shared.request("comment.unsubscribe", params: [
                "subscriptionId": subscriptionId
            ])
            print("[CommentStore] Unsubscribed: \(subscriptionId)")
        } catch {
            print("[CommentStore] comment.unsubscribe failed: \(error)")
        }
    }
    
    // MARK: - Event handling

    func handleEvent(_ method: String, params: Any) {
        // Handle subscription.push for live-state updates
        if let push = SubscriptionPush.parse(method: method, params: params) {
            handleSubscriptionPush(push)
            return
        }

        // Legacy event handling (only if not live)
        if !commentLive {
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

        // Gate on subscriptionId to avoid cross-contamination from other channels
        // (ConnectionManager broadcasts all subscription.push to all handlers)
        // Accept pushes if subscriptionId is nil (tiny window before response returns)
        if let subId = commentSubscriptionId, push.subscriptionId != subId {
            return
        }

        switch push.kind {
        case .snapshot:
            guard let rawItems = push.snapshot else { return }
            commentLive = true
            reconciler.applySnapshot(seq: push.seq, rawItems: rawItems)
            threads = reconciler.values()
            print("[CommentStore] Applied snapshot with \(rawItems.count) threads, seq=\(push.seq)")

        case .delta:
            guard let delta = push.delta else { return }
            if reconciler.applyDelta(seq: push.seq, delta: delta) {
                threads = reconciler.values()
                print("[CommentStore] Applied delta seq=\(push.seq), added=\(delta.added.count), updated=\(delta.updated.count), removed=\(delta.removedIds.count)")
            } else {
                // Gap detected — resnapshot (guard against storm)
                if !resnapshotInProgress {
                    resnapshotInProgress = true
                    print("[CommentStore] Sequence gap detected at seq=\(push.seq), resubscribing...")
                    Task { await resnapshot() }
                }
            }
        }
    }

    private func resnapshot() async {
        resnapshotInProgress = true
        defer { resnapshotInProgress = false }

        commentLive = false
        commentReconciler?.reset()

        if let subId = commentSubscriptionId {
            await unsubscribe(subscriptionId: subId)
        }

        commentSubscriptionId = nil

        // Re-subscribe
        if let wsId = workspaceId, let noteId = currentNoteId {
            await subscribeLiveState(workspaceId: wsId, noteId: noteId)
        }
    }
}
