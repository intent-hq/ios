import Foundation
import Observation
import Synchronization
import Testing
import Combine
@testable import Intent

@MainActor
struct NoteStoreIntegrationTests {
    
    // MARK: - subscribeOnConnect
    
    @Test func subscribeOnConnect() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        
        // Configure responses
        fake.responseMap["note.list"] = ["notes": []]
        fake.responseMap["note.subscribe"] = [
            "subscriptionId": "sub-1",
            "seq": 0,
            "snapshot": []
        ]
        
        // Start connected
        fake.simulateConnect()
        
        // Fetch notes establishes workspace context and triggers subscribe
        await store.fetchNotes(workspaceId: "ws-1")
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // Verify subscribe was called
        #expect(fake.didCallMethod("note.subscribe"))
        #expect(fake.hasSubscriptionHandler(id: "sub-1"))
        
        // Deliver snapshot push to make the store live
        let push = SubscriptionPush(subscriptionId: "sub-1", kind: .snapshot, seq: 0, snapshot: [
            ["id": "note-1", "title": "Note 1", "content": "", "workspaceId": "ws-1", "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
        ], delta: nil)
        fake.deliverSubscriptionPush(push)
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // Verify state
        #expect(store.notes.count == 1)
    }
    
    // MARK: - contiguousDeltaAdvancesState
    
    @Test func contiguousDeltaAdvancesState() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        
        fake.responseMap["note.list"] = ["notes": []]
        fake.responseMap["note.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.simulateConnect()
        await store.fetchNotes(workspaceId: "ws-1")
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // Snapshot
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-1", kind: .snapshot, seq: 0, snapshot: [
            ["id": "note-1", "title": "Note 1", "content": "", "workspaceId": "ws-1", "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
        ], delta: nil))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.notes.count == 1)
        
        // Contiguous delta
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .delta,
            seq: 1,
            snapshot: nil,
            delta: SubscriptionPush.DeltaPayload(
                added: [["id": "note-2", "title": "Note 2", "content": "", "workspaceId": "ws-1", "createdAt": "2024-01-02T00:00:00Z", "updatedAt": "2024-01-02T00:00:00Z"]],
                updated: [],
                removedIds: []
            )
        ))
        try await Task.sleep(nanoseconds: 50_000_000)
        
        #expect(store.notes.count == 2)
    }
    
    // MARK: - gapTriggersResnapshotWithBaselineRefetch
    
    @Test func gapTriggersResnapshotWithBaselineRefetch() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        
        fake.responseMap["note.list"] = ["notes": []]
        fake.responseMap["note.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["note.unsubscribe"] = ["ok": true]
        fake.simulateConnect()
        await store.fetchNotes(workspaceId: "ws-1")
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // Snapshot
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-1", kind: .snapshot, seq: 0, snapshot: [
            ["id": "note-1", "title": "Note 1", "content": "", "workspaceId": "ws-1", "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
        ], delta: nil))
        try await Task.sleep(nanoseconds: 50_000_000)
        
        fake.clearRequestLog()
        
        // Gap (seq 5 instead of 1) triggers resnapshot
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .delta,
            seq: 5,
            snapshot: nil,
            delta: SubscriptionPush.DeltaPayload(added: [], updated: [], removedIds: [])
        ))
        try await Task.sleep(nanoseconds: 200_000_000)
        
        // Verify resnapshot: unsubscribe, subscribe, list
        #expect(fake.didCallMethod("note.unsubscribe"))
        #expect(fake.didCallMethod("note.subscribe"))
        #expect(fake.didCallMethod("note.list"))
    }
    
    // MARK: - connectionLossClearsLiveThenReconnectResubscribes
    
    @Test func connectionLossClearsLiveThenReconnectResubscribes() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        
        fake.responseMap["note.list"] = ["notes": []]
        fake.responseMap["note.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.simulateConnect()
        await store.fetchNotes(workspaceId: "ws-1")
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // Snapshot
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-1", kind: .snapshot, seq: 0, snapshot: [
            ["id": "note-1", "title": "Note 1", "content": "", "workspaceId": "ws-1", "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
        ], delta: nil))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.notes.count == 1)
        
        // Disconnect
        fake.clearRequestLog()
        fake.simulateDisconnect()
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Reconnect
        fake.simulateConnect()
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Verify fresh subscribe + list
        #expect(fake.didCallMethod("note.subscribe"))
        #expect(fake.didCallMethod("note.list"))
    }

    // MARK: - legacyEventSuppressedWhileLive

    @Test func legacyEventSuppressedWhileLive() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)

        fake.responseMap["note.list"] = ["notes": []]
        fake.responseMap["note.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.simulateConnect()
        await store.fetchNotes(workspaceId: "ws-1")
        try await Task.sleep(nanoseconds: 50_000_000)

        // Snapshot establishes live state
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-1", kind: .snapshot, seq: 0, snapshot: [
            ["id": "note-1", "title": "Note 1", "content": "", "workspaceId": "ws-1", "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
        ], delta: nil))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.notes.count == 1)

        fake.clearRequestLog()

        // Deliver legacy event (should be suppressed)
        fake.deliverEvent(method: "note.updated", params: [
            "event": [
                "type": "note:updated",
                "workspaceId": "ws-1",
                "noteId": "note-1"
            ]
        ])
        try await Task.sleep(nanoseconds: 100_000_000)

        // Verify no refetch (legacy event suppressed)
        #expect(!fake.didCallMethod("note.list"))
    }

    // MARK: - crossIdPushIsolation

    @Test func crossIdPushIsolation() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)

        fake.responseMap["note.list"] = ["notes": []]
        fake.responseMap["note.subscribe"] = ["subscriptionId": "sub-A", "seq": 0, "snapshot": []]
        fake.simulateConnect()
        await store.fetchNotes(workspaceId: "ws-1")
        try await Task.sleep(nanoseconds: 50_000_000)

        // Snapshot for sub-A
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-A", kind: .snapshot, seq: 0, snapshot: [
            ["id": "note-1", "title": "Note 1", "content": "", "workspaceId": "ws-1", "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
        ], delta: nil))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.notes.count == 1)

        // Push for unregistered sub-B (should be ignored by store)
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-B", kind: .snapshot, seq: 0, snapshot: [
            ["id": "note-99", "title": "Should not appear", "content": "", "workspaceId": "ws-1", "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
        ], delta: nil))
        try await Task.sleep(nanoseconds: 50_000_000)

        // Verify state unchanged
        #expect(store.notes.count == 1)
        #expect(store.notes[0].id == "note-1")
        #expect(!fake.hasSubscriptionHandler(id: "sub-B"))
    }

    // MARK: - fetchNote classification

    @Test func fetchNoteFoundReturnsNote() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.get"] = ["note": [
            "id": "note-1", "title": "Note 1", "content": "hello",
            "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"
        ]]

        let result = await store.fetchNote(noteId: "note-1", workspaceId: "ws-1")

        if case .found(let note) = result {
            #expect(note.id == "note-1")
        } else {
            Issue.record("Expected .found, got \(result)")
        }
    }

    @Test func fetchNoteNotFoundOnRpcNotFound() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        // note.get answers -32602 with data.code == "not-found" for a
        // nonexistent note (docs/PROTOCOL.md §3.3/§9)
        fake.errorMap["note.get"] = NSError(
            domain: "WebSocket", code: -32602,
            userInfo: [NSLocalizedDescriptionKey: "not found (-32602)",
                       NSError.intentErrorDataCodeKey: "not-found"])

        let result = await store.fetchNote(noteId: "note-gone", workspaceId: "ws-1")

        if case .notFound = result {
            // pass
        } else {
            Issue.record("Expected .notFound, got \(result)")
        }
    }

    @Test func fetchNoteTransientOnBare32602() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        // -32602 without data.code == "not-found" (invalid-params or a legacy
        // daemon omitting data) must NOT read as deletion (docs/PROTOCOL.md §9)
        fake.errorMap["note.get"] = NSError(
            domain: "WebSocket", code: -32602,
            userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: noteId"])

        let result = await store.fetchNote(noteId: "note-1", workspaceId: "ws-1")

        if case .transientError = result {
            // pass
        } else {
            Issue.record("Expected .transientError for a -32602 without data.code == \"not-found\", got \(result)")
        }
    }

    @Test func fetchNoteTransientOnInvalidParams32602() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.errorMap["note.get"] = NSError(
            domain: "WebSocket", code: -32602,
            userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: noteId",
                       NSError.intentErrorDataCodeKey: "invalid-params"])

        let result = await store.fetchNote(noteId: "note-1", workspaceId: "ws-1")

        if case .transientError = result {
            // pass
        } else {
            Issue.record("Expected .transientError for data.code == \"invalid-params\", got \(result)")
        }
    }

    @Test func fetchNoteArchivedTreatedAsNotFound() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.get"] = ["note": [
            "id": "note-1", "title": "Note 1", "content": "hello", "isArchived": true,
            "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"
        ]]

        let result = await store.fetchNote(noteId: "note-1", workspaceId: "ws-1")

        if case .notFound = result {
            // pass
        } else {
            Issue.record("Expected .notFound for archived note, got \(result)")
        }
    }

    @Test func fetchNoteTransientOnTimeout() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        // Transport-level timeout (ConnectionManager code -2) must not read as deletion
        fake.errorMap["note.get"] = NSError(
            domain: "WebSocket", code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Request timed out"])

        let result = await store.fetchNote(noteId: "note-1", workspaceId: "ws-1")

        if case .transientError = result {
            // pass
        } else {
            Issue.record("Expected .transientError, got \(result)")
        }
    }

    @Test func fetchNoteTransientOnGenericError() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.errorMap["note.get"] = NSError(
            domain: "SomeOtherDomain", code: -32602,
            userInfo: [NSLocalizedDescriptionKey: "unrelated failure"])

        let result = await store.fetchNote(noteId: "note-1", workspaceId: "ws-1")

        if case .transientError = result {
            // pass
        } else {
            Issue.record("Expected .transientError for non-RPC error, got \(result)")
        }
    }

    // MARK: - Slim note.list projection (PROTOCOL §5.2 projection: "slim")

    @Test func fetchNotesRequestsSlimProjection() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = ["notes": [
            ["id": "note-1", "title": "Note 1", "contentPreview": "preview",
             "contentLength": 900,
             "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
        ]]

        await store.fetchNotes(workspaceId: "ws-1")

        let params = fake.paramsForMethod("note.list")
        #expect(params.count == 1)
        #expect(params.first?["projection"] as? String == "slim")
        #expect(store.notes.count == 1)
        #expect(store.notes.first?.contentPreview == "preview")
        #expect(store.notes.first?.isContentStale == true)
    }

    @Test func fetchNotesFallsBackToFullListOn32602() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        // Daemon rejecting the projection param (-32602 Invalid params):
        // fetchNotes must retry once without it.
        fake.errorQueueMap["note.list"] = [NSError(
            domain: "WebSocket", code: -32602,
            userInfo: [NSLocalizedDescriptionKey: "Invalid params",
                       NSError.intentErrorDataCodeKey: "invalid-params"])]
        fake.responseMap["note.list"] = ["notes": [
            ["id": "note-1", "title": "Note 1", "content": "full body",
             "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
        ]]

        await store.fetchNotes(workspaceId: "ws-1")

        let params = fake.paramsForMethod("note.list")
        #expect(params.count == 2)
        #expect(params[0]["projection"] as? String == "slim")
        #expect(params[1]["projection"] == nil)
        #expect(store.notes.first?.content == "full body")
    }

    @Test func fetchNotesDoesNotRetryOnOtherErrors() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.errorMap["note.list"] = NSError(
            domain: "WebSocket", code: -32000,
            userInfo: [NSLocalizedDescriptionKey: "internal error"])

        await store.fetchNotes(workspaceId: "ws-1")

        #expect(fake.paramsForMethod("note.list").count == 1)
        #expect(store.notes.isEmpty)
    }

    @Test func slimReListKeepsLoadedContentAtSameUpdatedAt() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        // First list: full row already cached (e.g. hydrated via note.get).
        fake.responseMap["note.list"] = ["notes": [
            ["id": "note-1", "title": "Note 1", "content": "full body",
             "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
        ]]
        await store.fetchNotes(workspaceId: "ws-1")
        #expect(store.notes.first?.content == "full body")

        // Re-list serves a slim row at the same updatedAt: the loaded body
        // must not be clobbered.
        fake.responseMap["note.list"] = ["notes": [
            ["id": "note-1", "title": "Note 1", "contentPreview": "full bo",
             "contentLength": 9,
             "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
        ]]
        await store.fetchNotes(workspaceId: "ws-1")
        #expect(store.notes.first?.content == "full body")
        #expect(store.notes.first?.isContentStale == false)
    }

    @Test func slimReListDropsStaleContentOnNewerUpdatedAt() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = ["notes": [
            ["id": "note-1", "title": "Note 1", "content": "old body",
             "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
        ]]
        await store.fetchNotes(workspaceId: "ws-1")

        // Slim row with a different updatedAt: the cached body cannot be
        // proven current, so the stale marker must win.
        fake.responseMap["note.list"] = ["notes": [
            ["id": "note-1", "title": "Note 1", "contentPreview": "new bo",
             "contentLength": 8,
             "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-02T00:00:00Z"]
        ]]
        await store.fetchNotes(workspaceId: "ws-1")
        #expect(store.notes.first?.content == "")
        #expect(store.notes.first?.isContentStale == true)
    }

    @Test func fetchNotesHydratesStaleSpecRow() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        // Slim list with a stale spec row: the spec's content links task
        // notes (progress ring), so fetchNotes hydrates it via note.get.
        fake.responseMap["note.list"] = ["notes": [
            ["id": "spec", "title": "Spec", "isDefault": true,
             "contentPreview": "- [x] done", "contentLength": 40,
             "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"],
            ["id": "note-1", "title": "Note 1", "contentPreview": "p",
             "contentLength": 5,
             "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"],
        ]]
        fake.responseMap["note.get"] = ["note": [
            "id": "spec", "title": "Spec", "isDefault": true,
            "content": "- [x] done\n- [ ] todo item that overflows",
            "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"
        ]]

        await store.fetchNotes(workspaceId: "ws-1")

        #expect(fake.didCallMethod("note.get"))
        #expect(fake.paramsForMethod("note.get").first?["noteId"] as? String == "spec")
        let spec = store.note(byId: "spec")
        #expect(spec?.content == "- [x] done\n- [ ] todo item that overflows")
        // Non-spec rows stay slim.
        #expect(store.note(byId: "note-1")?.isContentStale == true)
    }

    @Test func cancelledFetchDoesNotPublishHydratedSpecBody() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = ["notes": [
            ["id": "spec", "title": "Spec", "isDefault": true,
             "contentPreview": "- [x] done", "contentLength": 40,
             "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
        ]]
        func fullSpec() -> [String: Any] {
            ["note": [
                "id": "spec", "title": "Spec", "isDefault": true,
                "content": "- [x] done\n- [ ] todo item that overflows",
                "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"
            ]]
        }

        // The list lands and publishes the slim spec row; the hydrating
        // note.get stays in flight.
        fake.pendingMethods.insert("note.get")
        let fetch = Task { await store.fetchNotes(workspaceId: "ws-1") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.note(byId: "spec")?.isContentStale == true)
        #expect(fake.paramsForMethod("note.get").count == 1)

        let changeCount = Mutex(0)
        withObservationTracking {
            _ = store.notes
        } onChange: {
            changeCount.withLock { $0 += 1 }
        }
        // Cancel and resolve back-to-back on the main actor: the fake's
        // cancellation hop is asynchronous, so note.get resumes with the
        // real body inside an already-cancelled fetch.
        fetch.cancel()
        fake.resolvePending("note.get", with: fullSpec())
        await fetch.value

        #expect(changeCount.withLock { $0 } == 0)
        #expect(store.note(byId: "spec")?.isContentStale == true)
        #expect(store.note(byId: "spec")?.content == "")
        #expect(store.isLoading == false)

        // A later, uncancelled fetch hydrates normally.
        fake.pendingMethods.remove("note.get")
        fake.responseMap["note.get"] = fullSpec()
        await store.fetchNotes(workspaceId: "ws-1")
        #expect(fake.paramsForMethod("note.get").count == 2)
        #expect(store.note(byId: "spec")?.content == "- [x] done\n- [ ] todo item that overflows")
        #expect(store.note(byId: "spec")?.isContentStale == false)
    }

    @Test func fetchNoteUpsertsFullBodyIntoCachedSlimRow() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = ["notes": [
            ["id": "note-1", "title": "Note 1", "contentPreview": "pre",
             "contentLength": 20,
             "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
        ]]
        await store.fetchNotes(workspaceId: "ws-1")
        #expect(store.note(byId: "note-1")?.isContentStale == true)

        fake.responseMap["note.get"] = ["note": [
            "id": "note-1", "title": "Note 1", "content": "hydrated full body",
            "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"
        ]]
        let result = await store.fetchNote(noteId: "note-1", workspaceId: "ws-1")
        if case .found = result {
            #expect(store.note(byId: "note-1")?.content == "hydrated full body")
        } else {
            Issue.record("Expected .found, got \(result)")
        }
    }

    @Test func fetchNoteDoesNotUpsertAcrossWorkspaces() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = ["notes": [
            ["id": "spec", "title": "Spec A", "content": "workspace A spec",
             "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
        ]]
        await store.fetchNotes(workspaceId: "ws-a")

        // A fetch for another workspace's same-id note must not clobber the
        // cache (note ids like "spec" repeat across workspaces).
        fake.responseMap["note.get"] = ["note": [
            "id": "spec", "title": "Spec B", "content": "workspace B spec",
            "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"
        ]]
        _ = await store.fetchNote(noteId: "spec", workspaceId: "ws-b")
        #expect(store.note(byId: "spec")?.content == "workspace A spec")
    }

    @Test func fetchNoteDoesNotClobberNewerCachedRow() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        // Cache advanced to a newer revision (delta/re-list) while a
        // note.get was in flight: the late older response must not replace
        // the row or clear its stale marker.
        fake.responseMap["note.list"] = ["notes": [
            ["id": "note-1", "title": "Note 1 (new)", "contentPreview": "newer",
             "contentLength": 10,
             "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-02T00:00:00Z"]
        ]]
        await store.fetchNotes(workspaceId: "ws-1")

        fake.responseMap["note.get"] = ["note": [
            "id": "note-1", "title": "Note 1 (old)", "content": "older body",
            "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"
        ]]
        let result = await store.fetchNote(noteId: "note-1", workspaceId: "ws-1")
        guard case .found(let fetched) = result else {
            Issue.record("Expected .found, got \(result)")
            return
        }
        // Caller still gets the fetched note, but the cache keeps the newer row.
        #expect(fetched.content == "older body")
        #expect(store.note(byId: "note-1")?.title == "Note 1 (new)")
        #expect(store.note(byId: "note-1")?.isContentStale == true)

        // A response at the cached revision (or newer) still replaces.
        fake.responseMap["note.get"] = ["note": [
            "id": "note-1", "title": "Note 1 (new)", "content": "current body",
            "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-02T00:00:00Z"
        ]]
        _ = await store.fetchNote(noteId: "note-1", workspaceId: "ws-1")
        #expect(store.note(byId: "note-1")?.content == "current body")
        #expect(store.note(byId: "note-1")?.isContentStale == false)
    }

    @Test func upsertFullNoteGraftsBodyOntoStaleSlimRow() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        // Detail view fetched the note BEFORE the list landed (fetchNote's
        // inline upsert had no row to replace), then the slim list arrives.
        fake.responseMap["note.get"] = ["note": [
            "id": "note-1", "title": "Note 1", "content": "full body",
            "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"
        ]]
        let result = await store.fetchNote(noteId: "note-1", workspaceId: "ws-1")
        guard case .found(let fetched) = result else {
            Issue.record("Expected .found, got \(result)")
            return
        }
        fake.responseMap["note.list"] = ["notes": [
            ["id": "note-1", "title": "Note 1", "contentPreview": "full b",
             "contentLength": 9,
             "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
        ]]
        await store.fetchNotes(workspaceId: "ws-1")
        #expect(store.note(byId: "note-1")?.isContentStale == true)

        store.upsertFullNote(fetched, workspaceId: "ws-1")
        #expect(store.note(byId: "note-1")?.content == "full body")
        #expect(store.note(byId: "note-1")?.isContentStale == false)
    }

    @Test func upsertFullNoteRefusesStaleBodyAndWrongWorkspace() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = ["notes": [
            ["id": "note-1", "title": "Note 1", "contentPreview": "newer",
             "contentLength": 10,
             "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-02T00:00:00Z"]
        ]]
        await store.fetchNotes(workspaceId: "ws-1")

        // Body fetched at an older revision must not clear the stale marker.
        let older = Note(
            id: "note-1", title: "Note 1", content: "older body", tags: [],
            isDefault: false, isArchived: false, taskStatus: nil,
            parentId: nil, createdAt: "2024-01-01T00:00:00Z",
            updatedAt: "2024-01-01T00:00:00Z")
        store.upsertFullNote(older, workspaceId: "ws-1")
        #expect(store.note(byId: "note-1")?.content == "")
        #expect(store.note(byId: "note-1")?.isContentStale == true)

        // Same revision but wrong workspace: refused too.
        let current = Note(
            id: "note-1", title: "Note 1", content: "current body", tags: [],
            isDefault: false, isArchived: false, taskStatus: nil,
            parentId: nil, createdAt: "2024-01-01T00:00:00Z",
            updatedAt: "2024-01-02T00:00:00Z")
        store.upsertFullNote(current, workspaceId: "ws-other")
        #expect(store.note(byId: "note-1")?.content == "")

        // Same revision, right workspace: grafts.
        store.upsertFullNote(current, workspaceId: "ws-1")
        #expect(store.note(byId: "note-1")?.content == "current body")
    }

    // MARK: - note:deleted event triggers onNoteChanged

    @Test func noteDeletedEventTriggersOnNoteChanged() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = ["notes": []]
        store.startObservingEvents(workspaceId: "ws-1")

        var called = false
        store.onNoteChanged = { called = true }

        fake.deliverEvent(method: "events.event", params: [
            "event": ["type": "note:deleted", "workspaceId": "ws-1", "noteId": "note-1"]
        ])
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(called, "note:deleted must invoke onNoteChanged so the detail view can re-validate")
    }

    // MARK: - Event allowlist (non-live fallback)

    @Test func allowlistedNoteEventRefetchesAndFiresCallbackWhenNotLive() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = ["notes": []]
        store.startObservingEvents(workspaceId: "ws-1")

        var called = false
        store.onNoteChanged = { called = true }

        fake.deliverEvent(method: "events.event", params: [
            "event": ["type": "note:updated", "workspaceId": "ws-1", "noteId": "note-1"]
        ])
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(fake.didCallMethod("note.list"))
        #expect(called)
    }

    @Test func noteCreatedRefetchesButDoesNotFireOnNoteChanged() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = ["notes": []]
        store.startObservingEvents(workspaceId: "ws-1")

        var called = false
        store.onNoteChanged = { called = true }

        fake.deliverEvent(method: "events.event", params: [
            "event": ["type": "note:created", "workspaceId": "ws-1", "noteId": "note-2"]
        ])
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(fake.didCallMethod("note.list"), "a new note changes list membership")
        #expect(!called, "a newly created note can never be the open note; refreshNote is not needed")
    }

    @Test func nonAllowlistedEventsDoNotRefetchOrFireCallback() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = ["notes": []]
        store.startObservingEvents(workspaceId: "ws-1")

        var called = false
        store.onNoteChanged = { called = true }

        for type in ["comment:added", "comment:resolved", "note:archived", "task:status-changed"] {
            fake.deliverEvent(method: "events.event", params: [
                "event": ["type": type, "workspaceId": "ws-1", "noteId": "note-1"]
            ])
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!fake.didCallMethod("note.list"))
        #expect(!called)
    }

    // MARK: - deinit removes event + subscription handlers (monorepo#2211, monorepo#2213)

    @Test func deinitRemovesEventHandler() async throws {
        let fake = FakeConnectionManager()
        var store: NoteStore? = NoteStore(connectionManager: fake)

        fake.responseMap["note.list"] = ["notes": []]
        fake.responseMap["note.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        store?.startObservingEvents(workspaceId: "ws-1")
        fake.simulateConnect()
        await store?.fetchNotes(workspaceId: "ws-1")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(fake.eventHandlerCount == 1)
        #expect(fake.subscriptionHandlerCount == 1)

        store = nil
        // deinit hops to the main actor to remove the handlers; wait for that task
        for _ in 0..<40 {
            if fake.eventHandlerCount == 0 && fake.subscriptionHandlerCount == 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(fake.eventHandlerCount == 0)
        #expect(fake.subscriptionHandlerCount == 0)
    }

    // MARK: - Identical refetch stays quiet (no re-render underneath swipe-back)

    @Test func identicalRefetchDoesNotReassignNotes() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = ["notes": [
            ["id": "note-1", "title": "Note 1", "content": "",
             "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
        ]]
        await store.fetchNotes(workspaceId: "ws-1")
        #expect(store.hasLoaded == true)
        #expect(store.notes.count == 1)

        // The deferred refresh after re-appearing for the same workspace
        // returns the same list: no observed property may be invalidated.
        let changeCount = Mutex(0)
        withObservationTracking {
            _ = store.notes
            _ = store.hasLoaded
            _ = store.isLoading
        } onChange: {
            changeCount.withLock { $0 += 1 }
        }
        await store.fetchNotes(workspaceId: "ws-1")
        #expect(fake.paramsForMethod("note.list").count == 2)
        #expect(changeCount.withLock { $0 } == 0)
        #expect(store.notes.count == 1)

        // A genuinely different list must still publish.
        fake.responseMap["note.list"] = ["notes": [
            ["id": "note-1", "title": "Note 1", "content": "",
             "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"],
            ["id": "note-2", "title": "Note 2", "content": "",
             "createdAt": "2024-01-02T00:00:00Z", "updatedAt": "2024-01-02T00:00:00Z"]
        ]]
        await store.fetchNotes(workspaceId: "ws-1")
        #expect(changeCount.withLock { $0 } == 1)
        #expect(store.notes.map(\.id) == ["note-1", "note-2"])
    }

    // MARK: - hasLoaded gating (empty state waits for first completed load)

    @Test func hasLoadedFalseUntilFirstFetchSucceeds() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        #expect(store.hasLoaded == false)

        fake.pendingMethods.insert("note.list")
        let fetch = Task { await store.fetchNotes(workspaceId: "ws-1") }
        try await Task.sleep(nanoseconds: 100_000_000)
        // Fetch in flight: still not loaded
        #expect(store.hasLoaded == false)
        #expect(store.isLoading == true)

        // An empty successful result is a legitimate empty state
        fake.resolvePending("note.list", with: ["notes": []])
        await fetch.value
        #expect(store.hasLoaded == true)
        #expect(store.isLoading == false)
        #expect(store.notes.isEmpty)
    }

    @Test func failedFetchLeavesHasLoadedFalse() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        // ConnectionManager.request throws immediately while the socket is
        // still connecting ("Not connected") — must not flip to empty state.
        fake.errorMap["note.list"] = NSError(
            domain: "WebSocket", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Not connected"])

        await store.fetchNotes(workspaceId: "ws-1")

        #expect(store.hasLoaded == false)
        #expect(store.isLoading == false)
    }

    @Test func workspaceChangeResetsHasLoaded() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = ["notes": [
            ["id": "note-1", "title": "Note 1", "content": "",
             "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
        ]]
        await store.fetchNotes(workspaceId: "ws-1")
        #expect(store.hasLoaded == true)

        // Switching workspaces resets the gate; the failed fetch for the new
        // workspace keeps it false.
        fake.responseMap.removeValue(forKey: "note.list")
        fake.errorMap["note.list"] = NSError(
            domain: "WebSocket", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        await store.fetchNotes(workspaceId: "ws-2")
        #expect(store.hasLoaded == false)
        #expect(store.notes.isEmpty)
    }

    @Test func staleFetchForPreviousWorkspaceDoesNotFlipHasLoaded() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.pendingMethods.insert("note.list")

        let staleFetch = Task { await store.fetchNotes(workspaceId: "ws-1") }
        try await Task.sleep(nanoseconds: 50_000_000)
        let currentFetch = Task { await store.fetchNotes(workspaceId: "ws-2") }
        try await Task.sleep(nanoseconds: 50_000_000)

        // The stale ws-1 fetch completing must not mark ws-2 as loaded
        // nor replace ws-2's notes with ws-1's.
        fake.resolvePending("note.list", with: ["notes": [
            ["id": "note-1", "title": "Old", "content": "",
             "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
        ]])
        await staleFetch.value
        #expect(store.hasLoaded == false)
        #expect(store.notes.isEmpty)

        fake.resolvePending("note.list", with: ["notes": []])
        await currentFetch.value
        #expect(store.hasLoaded == true)
    }

    @Test func prepareForWorkspaceChangeResetsSynchronously() async {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        fake.responseMap["note.list"] = ["notes": [
            ["id": "note-1", "title": "Note 1", "content": "",
             "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
        ]]
        await store.fetchNotes(workspaceId: "ws-1")
        #expect(store.hasLoaded == true)

        // Same workspace: no-op (re-appear must not flash the loading state)
        store.prepareForWorkspaceChange(to: "ws-1")
        #expect(store.hasLoaded == true)
        #expect(store.notes.count == 1)

        // Different workspace: resets synchronously, before any fetch runs
        store.prepareForWorkspaceChange(to: "ws-2")
        #expect(store.hasLoaded == false)
        #expect(store.notes.isEmpty)
    }
}
