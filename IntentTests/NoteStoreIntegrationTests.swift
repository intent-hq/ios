import Foundation
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
}
