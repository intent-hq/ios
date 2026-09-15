import Foundation
import Combine
import Observation

@MainActor
@Observable class NoteStore {
    var notes: [Note] = []
    var isLoading = false
    /// True once a `note.list` for the current workspace has completed
    /// successfully. Reset on workspace change; a failed fetch leaves it
    /// false so views keep the loading placeholder instead of "No notes".
    var hasLoaded = false

    private var workspaceId: String?
    @ObservationIgnored private var eventHandlerId: UUID?
    let connectionManager: ConnectionManagerRouting

    // Live-state tracking (subscription.push)
    private var noteLive = false
    @ObservationIgnored private var noteSubscriptionId: String?
    private var noteReconciler: DeltaReconciler<Note>?
    private var resnapshotInProgress = false
    private var connectionObserver: AnyCancellable?

    /// Live `noteChanges()` streams, keyed per consumer; see `noteChanges()`.
    @ObservationIgnored private var noteChangeContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    init(connectionManager: ConnectionManagerRouting = ConnectionManager.shared) {
        self.connectionManager = connectionManager
        observeConnection()
    }

    isolated deinit {
        for continuation in noteChangeContinuations.values {
            continuation.finish()
        }
        // Remove handlers directly while deinit is isolated to MainActor.
        guard eventHandlerId != nil || noteSubscriptionId != nil else { return }
        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
        }
        if let subscriptionId = noteSubscriptionId {
            connectionManager.unregisterSubscriptionHandler(id: subscriptionId)
        }
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

    /// Synchronously reset the list and load gate for a workspace switch.
    /// Views call this from onChange(of: workspaceId) before scheduling the
    /// async fetch, so the empty state cannot render with the previous
    /// workspace's hasLoaded while the fetch task has not started yet.
    func prepareForWorkspaceChange(to workspaceId: String) {
        guard self.workspaceId != workspaceId else { return }
        notes = []
        hasLoaded = false
    }

    func fetchNotes(workspaceId: String) async {
        let workspaceChanged = self.workspaceId != workspaceId
        // If workspace changed, clear notes immediately to prevent stale data
        if workspaceChanged {
            notes = []
            hasLoaded = false
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
            let items = try await requestNoteList(workspaceId: workspaceId)
            // Guard: a stale response for a previous workspace must not
            // replace the current workspace's notes or flip hasLoaded. The
            // current workspace's own fetch manages isLoading.
            guard self.workspaceId == workspaceId else { return }
            // A fetch cancelled while its request was in flight must not
            // publish the late response either.
            try Task.checkCancellation()
            // Only publish a changed list: an identical refetch (e.g. the
            // deferred refresh after swiping back to the workspace) must not
            // invalidate observers and rebuild the note list.
            let merged = mergeSlimRows(items.compactMap { Note.parseNote($0) })
            if merged != notes {
                notes = merged
            }
            if !hasLoaded {
                hasLoaded = true
            }
            // The spec is the one structural exception (its content links task
            // notes for the progress ring), so hydrate it full when its slim
            // row is stale. Fail-soft: a miss keeps the slim row as-is.
            if let specId = notes.first(where: { $0.isDefault && $0.isContentStale })?.id {
                _ = await fetchNote(noteId: specId, workspaceId: workspaceId)
            }
        } catch is CancellationError {
            // Cancelled refresh: nothing to publish, nothing to log.
        } catch {
            AppLog.notes.error("[NoteStore] Failed to fetch notes: \(error)")
        }
        if isLoading {
            isLoading = false
        }
        // Note: live-state subscription is owned by onConnected() lifecycle.
        // Direct fetchNotes() calls (e.g., user pull-to-refresh) do NOT auto-subscribe.
    }

    /// `note.list` with the slim projection (PROTOCOL §5.2 `projection:
    /// "slim"`): bounded rows carrying `contentPreview`/`contentLength`
    /// instead of full `content`, so note-heavy workspaces don't pull multi-MB
    /// frames. If the daemon rejects the param (-32602 Invalid params —
    /// defense-in-depth: pre-8.1 daemons ignore unknown params and serve full
    /// rows instead), fall back once to the plain full list; other failures
    /// propagate unchanged.
    private func requestNoteList(workspaceId: String) async throws -> [[String: Any]] {
        let result: Any
        do {
            result = try await connectionManager.request(
                "note.list",
                params: ["workspaceId": workspaceId, "projection": "slim"]
            )
        } catch let error as NSError where error.domain == "WebSocket" && error.code == -32602 {
            AppLog.notes.warning(
                "[NoteStore] note.list rejected projection param, retrying full: \(error)")
            result = try await connectionManager.request(
                "note.list",
                params: ["workspaceId": workspaceId]
            )
        }
        guard let dict = result as? [String: Any],
              let items = dict["notes"] as? [[String: Any]] else { return [] }
        return items
    }

    /// Slim-projection merge (§5.2): a slim row carries no content, so when
    /// the cache already holds the full body at the same `updatedAt`, keep
    /// it — a re-list must never clobber loaded content. A slim row with a
    /// different `updatedAt` wins as-is: the stale marker makes content
    /// surfaces refetch via `note.get`, which is safer than keeping a
    /// possibly-outdated body.
    private func mergeSlimRows(_ incoming: [Note]) -> [Note] {
        guard !notes.isEmpty else { return incoming }
        let existingById = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return incoming.map { row in
            guard row.isContentStale,
                  let existing = existingById[row.id],
                  !existing.content.isEmpty,
                  existing.updatedAt == row.updatedAt else { return row }
            return row.withContent(existing.content)
        }
    }

    /// Graft an already-fetched full body onto a cached slim list row (§5.2).
    /// For detail views that fetched the note before the slim list landed —
    /// `fetchNote`'s own upsert had no row (and no workspace context) to
    /// replace then. Same-workspace, same-`updatedAt`, stale-row only: a
    /// newer slim row keeps its stale marker so content surfaces refetch
    /// instead of rendering an outdated body.
    func upsertFullNote(_ note: Note, workspaceId: String) {
        guard self.workspaceId == workspaceId,
              !note.content.isEmpty,
              let idx = notes.firstIndex(where: { $0.id == note.id }),
              notes[idx].isContentStale,
              notes[idx].updatedAt == note.updatedAt else { return }
        notes[idx] = notes[idx].withContent(note.content)
    }

    /// True when the cached row carries a strictly newer `updatedAt` than
    /// the fetched note. Timestamps are parsed leniently; an unparseable
    /// side compares as not-newer, preserving the replace behavior.
    private static func isCachedRowNewer(_ cached: Note, thanFetched fetched: Note) -> Bool {
        guard cached.updatedAt != fetched.updatedAt,
              let cachedDate = ISO8601DateFormatter.lenientDate(from: cached.updatedAt),
              let fetchedDate = ISO8601DateFormatter.lenientDate(from: fetched.updatedAt)
        else { return false }
        return cachedDate > fetchedDate
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
            // A fetch cancelled while note.get was in flight (e.g. the
            // deferred swipe-back refresh hydrating the spec after the view
            // disappeared) must not publish the late body.
            try Task.checkCancellation()
            if let dict = result as? [String: Any],
               let noteDict = dict["note"] as? [String: Any],
               let note = Note.parseNote(noteDict) {
                if note.isArchived { return .notFound }
                // Upsert the full body over a cached slim list row (§5.2) so
                // content surfaces and optimistic content edits work off the
                // cache. Replace-only: never grows the list, only for the
                // workspace the cache belongs to (note ids like "spec" repeat
                // across workspaces), and never over a newer cached row — a
                // delta/re-list may have advanced it while this note.get was
                // in flight, and a late older body must not clobber it or
                // clear its stale marker.
                if self.workspaceId == workspaceId,
                   let idx = notes.firstIndex(where: { $0.id == note.id }),
                   !Self.isCachedRowNewer(notes[idx], thanFetched: note) {
                    notes[idx] = note
                }
                return .found(note)
            }
            return .transientError
        } catch is CancellationError {
            // Cancelled fetch: nothing to publish, nothing to log.
            return .transientError
        } catch let error as NSError where error.isEntityNotFound {
            // A not-found that races the caller's cancellation (the response
            // resumed the request before the transport's cancellation cleanup
            // ran) must not navigate a dismissed screen away.
            return Task.isCancelled ? .transientError : .notFound
        } catch let error as NSError where error.domain == "WebSocket" && error.code == -32602 {
            // -32602 without data.code == "not-found" (invalid-params or absent
            // data, PROTOCOL §3.3/§9) — log loudly and treat as transient so a
            // client params bug doesn't silently masquerade as deletion.
            AppLog.notes.error(
                "[NoteStore] UNEXPECTED -32602 without data.code == \"not-found\" for "
                    + "note \(noteId) (data.code: \(error.intentErrorDataCode ?? "absent")) — "
                    + "NOT treating as deletion: \(error.localizedDescription)")
            return .transientError
        } catch {
            AppLog.notes.error("[NoteStore] Failed to fetch note: \(error)")
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
            AppLog.notes.error("[NoteStore] task.update failed: \(error)")
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
            AppLog.notes.error("[NoteStore] task.updateNoteStatus failed: \(error)")
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
                AppLog.notes.info("[NoteStore] Subscribed to note.subscribe: \(subId)")
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
            AppLog.notes.warning("[NoteStore] note.subscribe failed: \(error), falling back to legacy")
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

        // The refetch below runs only in the non-live fallback (no
        // `note.subscribe` snapshot yet, or after a subscription loss); while
        // live, deltas arrive via the subscription push and a refetch here
        // would double-apply.
        switch Self.classify(type: eventType, data: event["data"] as? [String: Any]) {
        case .refetch:
            if !noteLive {
                guard let workspaceId = workspaceId else { return }
                Task { await fetchNotes(workspaceId: workspaceId) }
            }
            // `noteChanges()` re-reads the note currently open in
            // `NoteDetailView` (`refreshNote`, which also navigates away on a
            // definitive not-found), so only an update or deletion is
            // relevant — a newly created note can never be the open one.
            if eventType != "note:created" {
                for continuation in noteChangeContinuations.values {
                    continuation.yield()
                }
            }
        case .patchInPlace, .ignore, nil:
            break
        }
    }

    /// Note-change notifications for the detail view: one element per note
    /// update/deletion event (`note:created` excluded, see `handleEvent`).
    /// The consuming task owns the subscription — cancelling it (SwiftUI's
    /// `.task` on disappearance) terminates the stream and drops the
    /// continuation, so the store never holds a closure that captures the
    /// view and no refresh runs after teardown. Events arriving while the
    /// consumer is busy coalesce into a single pending element.
    func noteChanges() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1))
        noteChangeContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.noteChangeContinuations[id] = nil
            }
        }
        return stream
    }

    // MARK: - Event classification

    /// Bus channels this store consumes. Every catalog type on them must be in
    /// exactly one table below (`IntentTests/EventCatalogCoverageTests.swift`).
    nonisolated static let handledChannels = ["note:"]

    /// Explicit allowlist (mirrors AgentStore / WorkspaceStore). intentd
    /// emits exactly three note types — `note:created`, `note:updated`,
    /// `note:deleted` — each with a `{ noteId, title, action }` payload that
    /// does not distinguish a body edit from a title/metadata write, so any
    /// of them can change a slim list row (title, updatedAt, contentPreview)
    /// or list membership. Comment/thread activity is its own `comment:*`
    /// family and never reaches this store; a `comment.add` that rewrites
    /// the note markdown rides `note:updated` and legitimately refreshes
    /// the row's preview/updatedAt.
    nonisolated static let refetchEventTypes: Set<String> = [
        "note:created", "note:updated", "note:deleted",
    ]

    /// No `note:` type is currently dropped. Any other `note:`-prefixed type
    /// a newer daemon adds is unclassified (ignored at runtime) until it is
    /// placed here or in `refetchEventTypes`.
    nonisolated static let ignoredEventTypes: Set<String> = []

    /// Pure classification of one event; `nil` means the tables above do not
    /// name the type, which `handleEvent` treats as ignore.
    nonisolated static func classify(type: String, data: [String: Any]?) -> EventClassification? {
        if refetchEventTypes.contains(type) { return .refetch }
        if ignoredEventTypes.contains(type) { return .ignore }
        return nil
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
            AppLog.notes.debug("[NoteStore] Applied snapshot with \(rawItems.count) notes, seq=\(push.seq)")

        case .delta:
            guard let delta = push.delta else { return }
            if reconciler.applyDelta(seq: push.seq, delta: delta) {
                notes = reconciler.values()
                AppLog.notes.debug("[NoteStore] Applied delta seq=\(push.seq), added=\(delta.added.count), updated=\(delta.updated.count), removed=\(delta.removedIds.count)")
            } else {
                // Gap detected — resnapshot (guard against storm)
                if !resnapshotInProgress {
                    resnapshotInProgress = true
                    AppLog.notes.warning("[NoteStore] Sequence gap detected at seq=\(push.seq), resubscribing...")
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
                AppLog.notes.error("[NoteStore] note.unsubscribe failed: \(error)")
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

