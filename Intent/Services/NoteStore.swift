import Combine
import Foundation
import Observation

@MainActor
@Observable class NoteStore {
    // JSON-RPC Invalid params, also used by the daemon for unknown entity ids.
    private static let invalidParametersErrorCode = -32_602

    var notes: [Note] = []
    /// The `note.list` read for the current workspace. Reset on workspace
    /// change; a failure before any success shows an error with Retry
    /// instead of "No notes" or an endless loading placeholder.
    var loadPhase = LoadPhase.idle
    var isLoading: Bool { loadPhase.isLoading }
    /// True once a `note.list` for the current workspace has succeeded.
    var hasLoaded: Bool { loadPhase.hasLoaded }

    var workspaceId: String?
    @ObservationIgnored private var fetchRevision = 0
    @ObservationIgnored let eventRefreshes = CoalescedRead()
    @ObservationIgnored var eventHandlerId: UUID?
    let connectionManager: ConnectionManagerRouting

    // Live-state tracking (subscription.push)
    @ObservationIgnored var liveSubscription = LiveSubscription.idle
    @ObservationIgnored var liveSubscriptionGeneration = 0
    @ObservationIgnored var noteReconciler: DeltaReconciler<Note>?
    @ObservationIgnored var connectionObserver: AnyCancellable?
    @ObservationIgnored private var connectionObservationID = UUID()
    /// Reads the rest of a paged `note.subscribe` snapshot (protocol §6.9).
    @ObservationIgnored let snapshotFiller = PagedSnapshotFiller()
    /// Test seam for the whole-note read's page retry backoff.
    @ObservationIgnored var pageRetrySleep: PagedReads.Sleep = PagedReads.defaultSleep

    /// Optional callback invoked when a note event is received (for detail view refresh)
    var onNoteChanged: (() -> Void)?
    @ObservationIgnored var noteChangeContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    init(connectionManager: ConnectionManagerRouting = ConnectionManager.shared) {
        self.connectionManager = connectionManager
        observeConnection()
    }

    isolated deinit {
        eventRefreshes.cancel()
        for continuation in noteChangeContinuations.values {
            continuation.finish()
        }
        // Remove handlers directly while deinit is isolated to MainActor.
        guard eventHandlerId != nil || liveSubscription.id != nil else { return }
        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
        }
        if let subscriptionId = liveSubscription.id {
            connectionManager.unregisterSubscriptionHandler(id: subscriptionId)
        }
    }

    // MARK: - Connection observation

    func observeConnection(dropInitialState: Bool = false) {
        let observationID = UUID()
        connectionObservationID = observationID
        connectionObserver = connectionManager.connectionStatePublisher
            .dropFirst(dropInitialState ? 1 : 0)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, connectionObserver != nil,
                      connectionObservationID == observationID, state == .connected else { return }
                scheduleReconnect()
            }
    }

    /// Fence both queued delivery and execution: cancelling a Combine observer
    /// cannot cancel a reconnect task it has already scheduled.
    @discardableResult
    func scheduleReconnect() -> Task<Void, Never> {
        let observationID = connectionObservationID
        let generation = liveSubscriptionGeneration
        return Task { [weak self] in
            guard let self, connectionObserver != nil,
                  connectionObservationID == observationID,
                  liveSubscriptionGeneration == generation else { return }
            await onConnected()
        }
    }

    func onConnected() async {
        // Reset live-state tracking on new connection. Unregister the old
        // handler if reconnecting (defensive: subscription is invalid after disconnect)
        liveSubscriptionGeneration &+= 1
        if let oldId = liveSubscription.reset() {
            connectionManager.unregisterSubscriptionHandler(id: oldId)
        }
        noteReconciler = nil
        snapshotFiller.cancel()

        // If we have a workspace context, refetch and subscribe
        if let workspaceId {
            let generation = liveSubscriptionGeneration
            await fetchNotes(workspaceId: workspaceId)
            guard generation == liveSubscriptionGeneration, self.workspaceId == workspaceId else { return }
            await subscribeLiveState(workspaceId: workspaceId, generation: generation)
        }
    }

    // MARK: - Fetch

    /// Synchronously reset the list and load gate for a workspace switch.
    /// Views call this from onChange(of: workspaceId) before scheduling the
    /// async fetch, so the empty state cannot render with the previous
    /// workspace's load phase while the fetch task has not started yet.
    func prepareForWorkspaceChange(to workspaceId: String) {
        guard self.workspaceId != workspaceId else { return }
        fetchRevision &+= 1
        eventRefreshes.cancel()
        notes = []
        loadPhase = .idle
    }

    private func setLoadPhase(_ next: LoadPhase) {
        if next != loadPhase { loadPhase = next }
    }

    private func isCurrentFetch(workspaceId: String, revision: Int) -> Bool {
        self.workspaceId == workspaceId && fetchRevision == revision
    }

    private func resetForFetchIfWorkspaceChanged(to workspaceId: String) {
        guard self.workspaceId != workspaceId else { return }
        eventRefreshes.cancel()
        notes = []
        loadPhase = .idle
        liveSubscriptionGeneration &+= 1
        if let oldId = liveSubscription.reset() {
            connectionManager.unregisterSubscriptionHandler(id: oldId)
        }
        noteReconciler = nil
        snapshotFiller.cancel()
    }

    func fetchNotes(workspaceId: String) async {
        // If workspace changed, clear notes immediately to prevent stale data.
        resetForFetchIfWorkspaceChanged(to: workspaceId)
        self.workspaceId = workspaceId
        fetchRevision &+= 1
        let requestRevision = fetchRevision
        // Only the first read shows loading; refreshes keep the list as is.
        if !hasLoaded { setLoadPhase(loadPhase.beginning()) }
        defer {
            if isCurrentFetch(workspaceId: workspaceId, revision: requestRevision) {
                setLoadPhase(loadPhase.settled())
            }
        }
        do {
            let items = try await requestNoteList(workspaceId: workspaceId)
            // Ignore stale responses for a previous workspace or superseded same-workspace read.
            guard isCurrentFetch(workspaceId: workspaceId, revision: requestRevision) else { return }
            // A cancelled fetch must not publish its late response.
            try Task.checkCancellation()
            // Avoid invalidating observers for an identical refetch.
            let merged = mergeSlimRows(items.compactMap { Note.parseNote($0) })
            if merged != notes {
                notes = merged
            }
            if !hasLoaded { setLoadPhase(.loaded(Date())) }
            // Hydrate a stale spec because its content links task notes.
            if let specId = notes.first(where: { $0.isDefault && $0.isContentStale })?.id {
                _ = await fetchNote(noteId: specId, workspaceId: workspaceId)
            }
        } catch is CancellationError {
        } catch {
            AppLog.notes.error("[NoteStore] Failed to fetch notes: \(error)")
            if isCurrentFetch(workspaceId: workspaceId, revision: requestRevision) {
                setLoadPhase(loadPhase.failing(error))
            }
        }
        // Live-state subscription is owned by onConnected().
    }

    /// `note.list` with the slim projection (PROTOCOL §5.2 `projection:
    /// "slim"`): bounded rows carrying `contentPreview`/`contentLength`
    /// instead of full `content`, so note-heavy workspaces don't pull multi-MB
    /// frames. Every page is read (§5.2 "Bounded note and comment reads":
    /// `limit` + `nextToken`; daemons without paging answer the whole list).
    /// If the daemon rejects the param (-32602 Invalid params —
    /// defense-in-depth: pre-8.1 daemons ignore unknown params and serve full
    /// rows instead), fall back once to the plain full list; other failures
    /// propagate unchanged.
    private func requestNoteList(workspaceId: String) async throws -> [[String: Any]] {
        let page: PagedReads.Request = { [connectionManager] params in
            try await connectionManager.request("note.list", params: params)
        }
        do {
            return try await PagedReads.requestAllPages(
                params: ["workspaceId": workspaceId, "projection": "slim", "limit": PagedReads.notePageLimit],
                field: "notes",
                request: page
            )
        } catch let error as NSError
            where error.domain == "WebSocket" && error.code == Self.invalidParametersErrorCode {
            AppLog.notes.warning(
                "[NoteStore] note.list rejected projection param, retrying full: \(error)"
            )
            return try await PagedReads.requestAllPages(
                params: ["workspaceId": workspaceId, "limit": PagedReads.notePageLimit],
                field: "notes",
                request: page
            )
        }
    }

    /// Slim-projection merge (§5.2): a slim row carries no content, so when
    /// the cache already holds the full body at the same `updatedAt`, keep
    /// it (and its cut markers) — a re-list must never clobber loaded
    /// content. A slim row with a different `updatedAt` wins as-is: the stale
    /// marker makes content surfaces refetch via `note.get`, which is safer
    /// than keeping a possibly-outdated body.
    private func mergeSlimRows(_ incoming: [Note]) -> [Note] {
        guard !notes.isEmpty else { return incoming }
        let existingById = Dictionary(notes.map { ($0.id, $0) }) { existing, _ in existing }
        return incoming.map { row in
            guard row.isContentStale,
                  let existing = existingById[row.id],
                  !existing.content.isEmpty,
                  existing.updatedAt == row.updatedAt else { return row }
            return row.withBody(of: existing)
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
              notes[idx].needsFullContent,
              note.content.utf8.count >= notes[idx].content.utf8.count,
              notes[idx].updatedAt == note.updatedAt else { return }
        notes[idx] = notes[idx].withBody(of: note)
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
    /// A note too large for one read is joined from `contentOffset` pages
    /// (§5.2); if that fails the cut note comes back with `contentTruncated`.
    func fetchNote(noteId: String, workspaceId: String) async -> NoteFetchResult {
        do {
            let result = try await NoteContentPages.readWholeNote(
                params: ["noteId": noteId, "workspaceId": workspaceId],
                sleep: pageRetrySleep
            ) { [connectionManager] params in
                try await connectionManager.request("note.get", params: params)
            }
            // A cancelled fetch must not publish a late note body.
            try Task.checkCancellation()
            if let dict = result as? [String: Any],
               let noteDict = dict["note"] as? [String: Any],
               let note = Note.parseNote(noteDict) {
                if note.isArchived { return .notFound }
                // Replace a matching cached slim row, but never a newer row or
                // one from another workspace.
                // A cut fetch never replaces a cached whole body of the same revision.
                if self.workspaceId == workspaceId,
                   let idx = notes.firstIndex(where: { $0.id == note.id }),
                   !Self.isCachedRowNewer(notes[idx], thanFetched: note),
                   !(note.contentTruncated && !notes[idx].needsFullContent
                       && notes[idx].updatedAt == note.updatedAt) {
                    notes[idx] = note
                }
                return .found(note)
            }
            return .transientError
        } catch is CancellationError {
            return .transientError
        } catch let error as NSError where error.isEntityNotFound {
            // Ignore not-found when it races the caller's cancellation.
            return Task.isCancelled ? .transientError : .notFound
        } catch let error as NSError
            where error.domain == "WebSocket" && error.code == Self.invalidParametersErrorCode {
            // -32602 without data.code == "not-found" (invalid-params or absent
            // data, PROTOCOL §3.3/§9) — log loudly and treat as transient so a
            // client params bug doesn't silently masquerade as deletion.
            AppLog.notes.error(
                "[NoteStore] UNEXPECTED -32602 without data.code == \"not-found\" for "
                    + "note \(noteId) (data.code: \(error.intentErrorDataCode ?? "absent")) — "
                    + "NOT treating as deletion: \(error.localizedDescription)"
            )
            return .transientError
        } catch {
            AppLog.notes.error("[NoteStore] Failed to fetch note: \(error)")
            return .transientError
        }
    }
}
