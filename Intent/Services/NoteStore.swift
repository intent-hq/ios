import Combine
import Foundation
import Observation

@MainActor
@Observable class NoteStore {
    private static let invalidParametersErrorCode = -32_602

    var notes: [Note] = []
    var loadPhase = LoadPhase.idle
    var isLoading: Bool { loadPhase.isLoading }
    var hasLoaded: Bool { loadPhase.hasLoaded }

    var workspaceId: String?
    @ObservationIgnored private var fetchRevision = 0
    @ObservationIgnored let eventRefreshes = CoalescedRead()
    @ObservationIgnored var eventHandlerId: UUID?
    let connectionManager: ConnectionManagerRouting

    @ObservationIgnored var liveSubscription = LiveSubscription.idle
    @ObservationIgnored var liveSubscriptionGeneration = 0
    @ObservationIgnored var noteReconciler: DeltaReconciler<Note>?
    @ObservationIgnored var connectionObserver: AnyCancellable?
    @ObservationIgnored private var connectionObservationID = UUID()
    @ObservationIgnored let snapshotFiller = PagedSnapshotFiller()
    @ObservationIgnored var pageRetrySleep: PagedReads.Sleep = PagedReads.defaultSleep

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
        guard eventHandlerId != nil || liveSubscription.id != nil else { return }
        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
        }
        if let subscriptionId = liveSubscription.id {
            connectionManager.unregisterSubscriptionHandler(id: subscriptionId)
        }
    }

    func observeConnection(dropInitialState: Bool = false) {
        let observationID = UUID()
        connectionObservationID = observationID
        connectionObserver = connectionManager.connectionStatePublisher
            .dropFirst(dropInitialState ? 1 : 0)
            .map { [weak self] state in (state, self?.liveSubscriptionGeneration) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, generation in
                guard let self, let generation, connectionObserver != nil,
                      connectionObservationID == observationID, state == .connected else { return }
                scheduleReconnect(generation: generation)
            }
    }

    @discardableResult
    func scheduleReconnect(generation: Int? = nil) -> Task<Void, Never> {
        let observationID = connectionObservationID
        let generation = generation ?? liveSubscriptionGeneration
        return Task { [weak self] in
            guard let self, connectionObserver != nil,
                  connectionObservationID == observationID,
                  liveSubscriptionGeneration == generation else { return }
            await onConnected()
        }
    }

    func onConnected() async {
        liveSubscriptionGeneration &+= 1
        if let oldId = liveSubscription.reset() {
            connectionManager.unregisterSubscriptionHandler(id: oldId)
        }
        noteReconciler = nil
        snapshotFiller.cancel()

        if let workspaceId {
            let generation = liveSubscriptionGeneration
            await fetchNotes(workspaceId: workspaceId)
            guard generation == liveSubscriptionGeneration, self.workspaceId == workspaceId else { return }
            await subscribeLiveState(workspaceId: workspaceId, generation: generation)
        }
    }

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

    private func resetForFetchIfWorkspaceChanged(to workspaceId: String) -> Int? {
        guard self.workspaceId != workspaceId else { return nil }
        eventRefreshes.cancel()
        notes = []
        loadPhase = .idle
        liveSubscriptionGeneration &+= 1
        if let oldId = liveSubscription.reset() {
            connectionManager.unregisterSubscriptionHandler(id: oldId)
            if connectionManager.connectionState == .connected {
                let connection = connectionManager
                Task { _ = try? await connection.request("note.unsubscribe", params: ["subscriptionId": oldId]) }
            }
        }
        noteReconciler = nil
        snapshotFiller.cancel()
        return liveSubscriptionGeneration
    }

    func fetchNotes(workspaceId: String) async {
        let switchGeneration = resetForFetchIfWorkspaceChanged(to: workspaceId)
        await readNotes(workspaceId: workspaceId)
        if let switchGeneration {
            await subscribeAfterWorkspaceSwitch(workspaceId: workspaceId, generation: switchGeneration)
        }
    }

    private func subscribeAfterWorkspaceSwitch(workspaceId: String, generation: Int) async {
        guard !Task.isCancelled, generation == liveSubscriptionGeneration, self.workspaceId == workspaceId,
              connectionObserver != nil, connectionManager.connectionState == .connected,
              liveSubscription == .idle else { return }
        await subscribeLiveState(workspaceId: workspaceId, generation: generation)
    }

    private func readNotes(workspaceId: String) async {
        self.workspaceId = workspaceId
        fetchRevision &+= 1
        let requestRevision = fetchRevision
        if !hasLoaded { setLoadPhase(loadPhase.beginning()) }
        defer {
            if isCurrentFetch(workspaceId: workspaceId, revision: requestRevision) {
                setLoadPhase(loadPhase.settled())
            }
        }
        do {
            let items = try await requestNoteList(workspaceId: workspaceId)
            guard isCurrentFetch(workspaceId: workspaceId, revision: requestRevision) else { return }
            try Task.checkCancellation()
            let merged = mergeSlimRows(items.compactMap { Note.parseNote($0) })
            if merged != notes {
                notes = merged
            }
            if !hasLoaded { setLoadPhase(.loaded(Date())) }
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
    }

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

    func upsertFullNote(_ note: Note, workspaceId: String) {
        guard self.workspaceId == workspaceId,
              !note.content.isEmpty,
              let idx = notes.firstIndex(where: { $0.id == note.id }),
              notes[idx].needsFullContent,
              note.content.utf8.count >= notes[idx].content.utf8.count,
              notes[idx].updatedAt == note.updatedAt else { return }
        notes[idx] = notes[idx].withBody(of: note)
    }

    private static func isCachedRowNewer(_ cached: Note, thanFetched fetched: Note) -> Bool {
        guard cached.updatedAt != fetched.updatedAt,
              let cachedDate = ISO8601DateFormatter.lenientDate(from: cached.updatedAt),
              let fetchedDate = ISO8601DateFormatter.lenientDate(from: fetched.updatedAt)
        else { return false }
        return cachedDate > fetchedDate
    }

    enum NoteFetchResult {
        case found(Note)
        case notFound
        case transientError
    }

    func fetchNote(noteId: String, workspaceId: String) async -> NoteFetchResult {
        do {
            let result = try await NoteContentPages.readWholeNote(
                params: ["noteId": noteId, "workspaceId": workspaceId],
                sleep: pageRetrySleep
            ) { [connectionManager] params in
                try await connectionManager.request("note.get", params: params)
            }
            try Task.checkCancellation()
            if let dict = result as? [String: Any],
               let noteDict = dict["note"] as? [String: Any],
               let note = Note.parseNote(noteDict) {
                if note.isArchived { return .notFound }
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
            return Task.isCancelled ? .transientError : .notFound
        } catch let error as NSError
            where error.domain == "WebSocket" && error.code == Self.invalidParametersErrorCode {
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
