import Foundation
import Combine

@MainActor
class NoteStore: ObservableObject {
    @Published var notes: [Note] = []
    @Published var isLoading = false

    private var workspaceId: String?
    private var eventHandlerId: UUID?

    // Live-state tracking (subscription.push)
    private var noteLive = false
    private var noteSubscriptionId: String?
    private var noteReconciler: DeltaReconciler<Note>?
    private var resnapshotInProgress = false
    private var connectionObserver: AnyCancellable?

    /// Optional callback invoked when a note event is received (for detail view refresh)
    var onNoteChanged: (() -> Void)?

    init() {
        observeConnection()
    }

    /// Sorted notes: spec (isDefault) first, then by createdAt ascending (oldest first). Archived notes excluded.
    var sortedNotes: [Note] {
        notes
            .filter { !$0.isArchived }
            .sorted { a, b in
                if a.isDefault != b.isDefault {
                    return a.isDefault
                }
                // Match Electron behavior: sort by createdAt ascending (oldest first, newest at bottom)
                return a.createdAt < b.createdAt
            }
    }

    /// Root notes (no parentId, or parentId not found in current notes). Archived excluded.
    var rootNotes: [Note] {
        let noteIds = Set(notes.map { $0.id })
        return sortedNotes.filter { note in
            guard let parentId = note.parentId else { return true }
            return !noteIds.contains(parentId)
        }
    }

    /// Get child notes for a given parent ID, sorted by createdAt ascending.
    func childNotes(of parentId: String) -> [Note] {
        notes
            .filter { !$0.isArchived && $0.parentId == parentId }
            .sorted { a, b in a.createdAt < b.createdAt }
    }

    /// Check if a note has children
    func hasChildren(_ noteId: String) -> Bool {
        notes.contains { !$0.isArchived && $0.parentId == noteId }
    }

    /// Find a note by ID
    func note(byId id: String) -> Note? {
        notes.first { $0.id == id }
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
        noteLive = false
        noteSubscriptionId = nil
        noteReconciler = nil
        resnapshotInProgress = false

        // If we have a workspace context, refetch and subscribe
        if let workspaceId = workspaceId {
            await fetchNotes(workspaceId: workspaceId)
            await subscribeLiveState(workspaceId: workspaceId)
        }
    }

    // MARK: - Fetch

    func fetchNotes(workspaceId: String) async {
        let workspaceChanged = self.workspaceId != workspaceId
        // If workspace changed, clear notes immediately to prevent stale data
        if workspaceChanged {
            notes = []
            // Reset live-state for new workspace
            noteLive = false
            noteSubscriptionId = nil
            noteReconciler = nil
            resnapshotInProgress = false
        }
        self.workspaceId = workspaceId
        // Only show loading indicator if we have no notes to display
        if notes.isEmpty {
            isLoading = true
        }
        do {
            let result = try await ConnectionManager.shared.request(
                "note.list",
                params: ["workspaceId": workspaceId]
            )
            if let dict = result as? [String: Any],
               let items = dict["notes"] as? [[String: Any]] {
                notes = items.compactMap { Note.parseNote($0) }
            }
        } catch {
            print("[NoteStore] Failed to fetch notes: \(error)")
        }
        isLoading = false

        // Subscribe to live updates if connected (skip if already subscribed from onConnected)
        if ConnectionManager.shared.connectionState == .connected && noteReconciler == nil {
            await subscribeLiveState(workspaceId: workspaceId)
        }
    }

    func fetchNote(noteId: String, workspaceId: String) async -> Note? {
        do {
            let result = try await ConnectionManager.shared.request(
                "note.get",
                params: ["noteId": noteId, "workspaceId": workspaceId]
            )
            if let dict = result as? [String: Any],
               let noteDict = dict["note"] as? [String: Any] {
                return Note.parseNote(noteDict)
            }
        } catch {
            print("[NoteStore] Failed to fetch note: \(error)")
        }
        return nil
    }

    // MARK: - Live-state subscription

    private func subscribeLiveState(workspaceId: String) async {
        // Initialize note reconciler synchronously before await to eliminate race
        // (any push arriving between subscribe-sent and response-received will have a reconciler ready)
        noteReconciler = DeltaReconciler<Note>(
            getId: { dict in dict["id"] as? String },
            normalize: { dict in Note.parseNote(dict) }
        )

        // Try to subscribe - if server doesn't support it, error response falls back to legacy
        do {
            let result = try await ConnectionManager.shared.request("note.subscribe", params: [
                "workspaceId": workspaceId,
                "replaceGroup": "ios-notes-\(workspaceId)"
            ])
            if let dict = result as? [String: Any],
               let subId = dict["subscriptionId"] as? String {
                noteSubscriptionId = subId
                print("[NoteStore] Subscribed to note.subscribe: \(subId)")
            }
        } catch {
            print("[NoteStore] note.subscribe failed: \(error), falling back to legacy")
        }
    }

    // MARK: - Event subscription

    func startObservingEvents(workspaceId: String? = nil) {
        if let workspaceId = workspaceId {
            self.workspaceId = workspaceId
        }

        // Remove old handler to prevent accumulation on reconnect
        if let handlerId = eventHandlerId {
            ConnectionManager.shared.removeEventHandler(id: handlerId)
        }

        // Register event handler on ConnectionManager
        // (server subscription is handled centrally by ConnectionManager.subscribeToAllEvents)
        eventHandlerId = ConnectionManager.shared.onEvent { [weak self] method, params in
            Task { @MainActor [weak self] in
                self?.handleEvent(method, params: params)
            }
        }
    }

    private func handleEvent(_ method: String, params: Any) {
        // Handle subscription.push for live-state updates
        if let push = SubscriptionPush.parse(method: method, params: params) {
            handleSubscriptionPush(push)
            return
        }

        guard let dict = params as? [String: Any] else { return }

        let event: [String: Any]
        if let innerEvent = dict["event"] as? [String: Any] {
            event = innerEvent
        } else {
            event = dict
        }

        guard let eventType = event["type"] as? String else { return }

        let eventWorkspaceId = event["workspaceId"] as? String
        guard eventWorkspaceId == workspaceId || eventWorkspaceId == nil else { return }

        switch eventType {
        case let t where t.hasPrefix("note:"):
            // Only refetch if not in live mode (avoid double-apply)
            if !noteLive {
                guard let workspaceId = workspaceId else { return }
                Task { await fetchNotes(workspaceId: workspaceId) }
            }
            onNoteChanged?()
        default:
            break
        }
    }

    private func handleSubscriptionPush(_ push: SubscriptionPush) {
        // Only process pushes if we have a reconciler ready
        // (reconciler is initialized synchronously before subscribe request, so any
        // push arriving between subscribe-sent and response-received is safe to process)
        guard let reconciler = noteReconciler else {
            return
        }

        // Gate on subscriptionId to avoid cross-contamination from other channels
        // (ConnectionManager broadcasts all subscription.push to all handlers)
        if let subId = noteSubscriptionId, push.subscriptionId != subId {
            return
        }

        switch push.kind {
        case .snapshot:
            guard let rawItems = push.snapshot else { return }
            noteLive = true
            reconciler.applySnapshot(seq: push.seq, rawItems: rawItems)
            notes = reconciler.values()
            print("[NoteStore] Applied snapshot with \(rawItems.count) notes, seq=\(push.seq)")

        case .delta:
            guard let delta = push.delta else { return }
            if reconciler.applyDelta(seq: push.seq, delta: delta) {
                notes = reconciler.values()
                print("[NoteStore] Applied delta seq=\(push.seq), added=\(delta.added.count), updated=\(delta.updated.count), removed=\(delta.removedIds.count)")
            } else {
                // Gap detected — resnapshot (guard against storm)
                if !resnapshotInProgress {
                    resnapshotInProgress = true
                    print("[NoteStore] Sequence gap detected at seq=\(push.seq), resubscribing...")
                    Task { await resnapshot() }
                }
            }
        }
    }

    private func resnapshot() async {
        resnapshotInProgress = true
        defer { resnapshotInProgress = false }

        noteLive = false
        noteReconciler?.reset()

        if let subId = noteSubscriptionId {
            do {
                let _ = try await ConnectionManager.shared.request("note.unsubscribe", params: [
                    "subscriptionId": subId
                ])
            } catch {
                print("[NoteStore] note.unsubscribe failed: \(error)")
            }
        }

        noteSubscriptionId = nil

        if let workspaceId = workspaceId {
            await subscribeLiveState(workspaceId: workspaceId)
        }
    }
}

