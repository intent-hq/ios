import Combine
import Foundation
import Observation

@MainActor
@Observable class NoteStore {
    // JSON-RPC Invalid params, also used by the daemon for unknown entity ids.
    private static let invalidParametersErrorCode = -32_602

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
        snapshotFiller.cancel()
        resnapshotInProgress = false

        // If we have a workspace context, refetch and subscribe
        if let workspaceId {
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
            snapshotFiller.cancel()
            resnapshotInProgress = false
        }
        self.workspaceId = workspaceId
        // Only show loading indicator if we have no notes to display
        if notes.isEmpty {
            isLoading = true
        }
        do {
            let items = try await requestNoteList(workspaceId: workspaceId)
            // Ignore stale responses for a previous workspace.
            guard self.workspaceId == workspaceId else { return }
            // A cancelled fetch must not publish its late response.
            try Task.checkCancellation()
            // Avoid invalidating observers for an identical refetch.
            let merged = mergeSlimRows(items.compactMap { Note.parseNote($0) })
            if merged != notes {
                notes = merged
            }
            if !hasLoaded {
                hasLoaded = true
            }
            // Hydrate a stale spec because its content links task notes.
            if let specId = notes.first(where: { $0.isDefault && $0.isContentStale })?.id {
                _ = await fetchNote(noteId: specId, workspaceId: workspaceId)
            }
        } catch is CancellationError {
        } catch {
            AppLog.notes.error("[NoteStore] Failed to fetch notes: \(error)")
        }
        if isLoading {
            isLoading = false
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

extension NoteStore {
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
                "limit": PagedReads.notePageLimit,
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
            if !noteLive {
                guard let workspaceId else { return }
                Task { await fetchNotes(workspaceId: workspaceId) }
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
                if !resnapshotInProgress {
                    resnapshotInProgress = true
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
                guard let self, !resnapshotInProgress else { return }
                await resnapshot()
            }
        ))
    }

    private func resnapshot() async {
        resnapshotInProgress = true
        defer { resnapshotInProgress = false }

        noteLive = false
        noteReconciler?.reset()
        snapshotFiller.cancel()

        if let subId = noteSubscriptionId {
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

        noteSubscriptionId = nil

        if let workspaceId {
            await subscribeLiveState(workspaceId: workspaceId)
            // Baseline refetch to bridge the gap during resnapshot
            await fetchNotes(workspaceId: workspaceId)
        }
    }
}
