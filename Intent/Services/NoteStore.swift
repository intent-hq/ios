import Foundation
import Combine

@MainActor
class NoteStore: ObservableObject {
    @Published var notes: [Note] = []
    @Published var isLoading = false

    private var workspaceId: String?
    private var eventHandlerId: UUID?
    private let connectionManager: ConnectionManagerRouting

    // Live-state tracking (subscription.push)
    private var noteLive = false
    private var noteSubscriptionId: String?
    private var noteReconciler: DeltaReconciler<Note>?
    private var resnapshotInProgress = false
    private var connectionObserver: AnyCancellable?

    /// Optional callback invoked when a note event is received (for detail view refresh)
    var onNoteChanged: (() -> Void)?

    init(connectionManager: ConnectionManagerRouting = ConnectionManager.shared) {
        self.connectionManager = connectionManager
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
        connectionObserver = connectionManager.connectionStatePublisher
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
        // Unregister old handler if reconnecting (defensive: subscription is invalid after disconnect)
        if let oldId = noteSubscriptionId {
            connectionManager.unregisterSubscriptionHandler(id: oldId)
        }
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
            let result = try await connectionManager.request(
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
        // Note: live-state subscription is owned by onConnected() lifecycle.
        // Direct fetchNotes() calls (e.g., user pull-to-refresh) do NOT auto-subscribe.
    }

    /// Outcome of a single-note fetch, distinguishing a definitive not-found
    /// (deleted/archived) from transient transport errors.
    enum NoteFetchResult {
        case found(Note)
        case notFound
        case transientError
    }

    /// Fetch a single note. The daemon answers `-32602` with
    /// `data.code == "not-found"` for a nonexistent note (docs/PROTOCOL.md
    /// §3.3/§9) and archived notes are treated as gone; any other error is
    /// transient so callers don't mistake network blips for deletion.
    func fetchNote(noteId: String, workspaceId: String) async -> NoteFetchResult {
        do {
            let result = try await connectionManager.request(
                "note.get",
                params: ["noteId": noteId, "workspaceId": workspaceId]
            )
            if let dict = result as? [String: Any],
               let noteDict = dict["note"] as? [String: Any],
               let note = Note.parseNote(noteDict) {
                return note.isArchived ? .notFound : .found(note)
            }
            return .transientError
        } catch let error as NSError where error.isEntityNotFound {
            return .notFound
        } catch let error as NSError where error.domain == "WebSocket" && error.code == -32602 {
            // -32602 without data.code == "not-found" (invalid-params or absent
            // data, PROTOCOL §3.3/§9) — log loudly and treat as transient so a
            // client params bug doesn't silently masquerade as deletion.
            print(
                "[NoteStore] UNEXPECTED -32602 without data.code == \"not-found\" for "
                    + "note \(noteId) (data.code: \(error.intentErrorDataCode ?? "absent")) — "
                    + "NOT treating as deletion: \(error.localizedDescription)")
            return .transientError
        } catch {
            print("[NoteStore] Failed to fetch note: \(error)")
            return .transientError
        }
    }

    // MARK: - Task status writes

    /// Restore one note's pre-request snapshot after a failed optimistic
    /// write. Scoped to that note by id so concurrent deltas / optimistic
    /// writes to other notes that landed mid-flight are not clobbered; the
    /// note's own `note:updated` event reconciles any remaining drift.
    private func rollback(_ original: Note) {
        if let idx = notes.firstIndex(where: { $0.id == original.id }) {
            notes[idx] = original
        }
    }

    /// Update a plain checkbox line's status via the daemon's `task.update`
    /// (PROTOCOL §5.4 atomic single-line edit). `line` is 1-based; `status` is
    /// the checkbox vocabulary ("todo" | "in-progress" | "done"). The marker
    /// rewrite is applied optimistically to the local cache and reverted on
    /// error; the confirming `note:updated` event reconciles the real state.
    @discardableResult
    func updateTaskLineStatus(noteId: String, workspaceId: String, line: Int, status: String) async -> Bool {
        var original: Note?
        if let idx = notes.firstIndex(where: { $0.id == noteId }),
           let rewritten = NoteContentSegmenter.replacingCheckboxMarker(
               in: notes[idx].content, line: line, status: status) {
            original = notes[idx]
            notes[idx] = notes[idx].withContent(rewritten)
        }
        do {
            _ = try await connectionManager.request("task.update", params: [
                "workspaceId": workspaceId,
                "noteId": noteId,
                "line": line,
                "status": status,
            ])
            return true
        } catch {
            if let original { rollback(original) }
            print("[NoteStore] task.update failed: \(error)")
            return false
        }
    }

    /// Update a task note's metadata status via `task.updateNoteStatus`
    /// (PROTOCOL §5.4 task-note status vocabulary). Optimistic local update,
    /// reverted on error; `note:updated` confirms the change.
    @discardableResult
    func updateTaskNoteStatus(noteId: String, workspaceId: String, status: String) async -> Bool {
        var original: Note?
        if let idx = notes.firstIndex(where: { $0.id == noteId }) {
            original = notes[idx]
            notes[idx] = notes[idx].withTaskStatus(status)
        }
        do {
            _ = try await connectionManager.request("task.updateNoteStatus", params: [
                "workspaceId": workspaceId,
                "noteId": noteId,
                "status": status,
            ])
            return true
        } catch {
            if let original { rollback(original) }
            print("[NoteStore] task.updateNoteStatus failed: \(error)")
            return false
        }
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
            let result = try await connectionManager.request("note.subscribe", params: [
                "workspaceId": workspaceId,
                "replaceGroup": "ios-notes-\(workspaceId)"
            ])
            if let dict = result as? [String: Any],
               let subId = dict["subscriptionId"] as? String {
                // Unregister old handler if we had one
                if let oldId = noteSubscriptionId {
                    connectionManager.unregisterSubscriptionHandler(id: oldId)
                }
                noteSubscriptionId = subId
                // Register handler immediately in same MainActor tick (preserves sync-capture guarantee)
                connectionManager.registerSubscriptionHandler(id: subId) { [weak self] push in
                    self?.handleSubscriptionPush(push)
                }
                print("[NoteStore] Subscribed to note.subscribe: \(subId)")
            } else {
                // Response missing subscriptionId - clean up and fall back to legacy
                noteReconciler = nil
                noteSubscriptionId = nil
                noteLive = false
            }
        } catch {
            // Subscribe failed - clean up reconciler and fall back to legacy
            noteReconciler = nil
            noteSubscriptionId = nil
            noteLive = false
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

    private func handleEvent(_ method: String, params: Any) {
        // Handle subscription.push for live-state updates (test injection compatibility)
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

        // ConnectionManager now routes pushes by subscriptionId at the transport layer,
        // so this handler only receives pushes for our exact subscriptionId.
        // No per-store gate needed (single source of truth is the router)

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
            // Unregister handler before unsubscribing
            connectionManager.unregisterSubscriptionHandler(id: subId)
            do {
                let _ = try await connectionManager.request("note.unsubscribe", params: [
                    "subscriptionId": subId
                ])
            } catch {
                print("[NoteStore] note.unsubscribe failed: \(error)")
            }
        }

        noteSubscriptionId = nil

        if let workspaceId = workspaceId {
            await subscribeLiveState(workspaceId: workspaceId)
            // Baseline refetch to bridge the gap during resnapshot
            await fetchNotes(workspaceId: workspaceId)
        }
    }
}

