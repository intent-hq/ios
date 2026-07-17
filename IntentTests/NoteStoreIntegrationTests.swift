import Foundation
import Testing
import Combine
@testable import Intent

/// Store-level integration tests for NoteStore subscribe lifecycle.
/// These tests cover the full subscribe flow (not just the reconciler):
/// - Subscribe on connect
/// - Connection loss + reconnect
/// - Gap-triggered resnapshot + baseline refetch
/// - Legacy event suppression while live
/// - Cross-channel isolation (wrong subscriptionId)
@MainActor
struct NoteStoreIntegrationTests {

    @Test func subscribesOnConnect() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)

        // Set up fake response for note.subscribe
        fake.requestResponses["note.subscribe"] = ["subscriptionId": "sub-notes-123"]

        // Simulate connect
        fake.simulateConnect()

        // Give async tasks a moment to process
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Verify note.subscribe was called
        #expect(fake.didRequest(method: "note.subscribe"))

        // Inject snapshot
        fake.injectSubscriptionPush(
            subscriptionId: "sub-notes-123",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                [
                    "id": "note-1",
                    "title": "First Note",
                    "content": "Content 1",
                    "tags": [],
                    "isDefault": false,
                    "isArchived": false,
                    "createdAt": "2024-01-01T00:00:00Z",
                    "updatedAt": "2024-01-01T00:00:00Z"
                ]
            ]
        )

        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Verify store state matches snapshot
        #expect(store.notes.count == 1)
        #expect(store.notes[0].id == "note-1")
        #expect(store.notes[0].title == "First Note")
    }

    @Test func appliesContiguousDelta() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)

        fake.requestResponses["note.subscribe"] = ["subscriptionId": "sub-notes-123"]
        fake.simulateConnect()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Apply snapshot
        fake.injectSubscriptionPush(
            subscriptionId: "sub-notes-123",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                [
                    "id": "note-1",
                    "title": "First",
                    "content": "Content",
                    "tags": [],
                    "isDefault": false,
                    "isArchived": false,
                    "createdAt": "2024-01-01T00:00:00Z",
                    "updatedAt": "2024-01-01T00:00:00Z"
                ]
            ]
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        // Apply contiguous delta
        fake.injectSubscriptionPush(
            subscriptionId: "sub-notes-123",
            kind: .delta,
            seq: 1,
            delta: SubscriptionPush.DeltaPayload(
                added: [[
                    "id": "note-2",
                    "title": "Second",
                    "content": "Content 2",
                    "tags": [],
                    "isDefault": false,
                    "isArchived": false,
                    "createdAt": "2024-01-02T00:00:00Z",
                    "updatedAt": "2024-01-02T00:00:00Z"
                ]],
                updated: [],
                removedIds: []
            )
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(store.notes.count == 2)
        #expect(store.notes[0].id == "note-1")
        #expect(store.notes[1].id == "note-2")
    }

    @Test func gapTriggersResnapshotAndRefetch() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)

        fake.requestResponses["note.subscribe"] = ["subscriptionId": "sub-notes-123"]
        fake.requestResponses["note.list"] = [
            "notes": [
                [
                    "id": "note-1",
                    "title": "Refetched",
                    "content": "After gap",
                    "tags": [],
                    "isDefault": false,
                    "isArchived": false,
                    "createdAt": "2024-01-01T00:00:00Z",
                    "updatedAt": "2024-01-01T00:00:00Z"
                ]
            ]
        ]

        fake.simulateConnect()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Clear request log to track resnapshot flow
        fake.requestLog.removeAll()

        // Apply snapshot
        fake.injectSubscriptionPush(
            subscriptionId: "sub-notes-123",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                [
                    "id": "note-1",
                    "title": "First",
                    "content": "Content",
                    "tags": [],
                    "isDefault": false,
                    "isArchived": false,
                    "createdAt": "2024-01-01T00:00:00Z",
                    "updatedAt": "2024-01-01T00:00:00Z"
                ]
            ]
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        // Inject delta with gap (expected seq 1, got seq 5)
        fake.injectSubscriptionPush(
            subscriptionId: "sub-notes-123",
            kind: .delta,
            seq: 5,
            delta: SubscriptionPush.DeltaPayload(
                added: [],
                updated: [],
                removedIds: []
            )
        )

        // Give time for resnapshot flow
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        // Verify unsubscribe was called
        #expect(fake.didRequest(method: "note.unsubscribe"))

        // Verify resubscribe was called
        let subscribeRequests = fake.requestLog.filter { $0.method == "note.subscribe" }
        #expect(subscribeRequests.count >= 1)

        // Verify baseline refetch was called
        #expect(fake.didRequest(method: "note.list"))
    }

    @Test func connectionLossAndReconnect() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)

        fake.requestResponses["note.subscribe"] = ["subscriptionId": "sub-notes-123"]
        fake.requestResponses["note.list"] = ["notes": []]

        // Initial connect
        fake.simulateConnect()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Apply snapshot
        fake.injectSubscriptionPush(
            subscriptionId: "sub-notes-123",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                [
                    "id": "note-1",
                    "title": "Before disconnect",
                    "content": "Content",
                    "tags": [],
                    "isDefault": false,
                    "isArchived": false,
                    "createdAt": "2024-01-01T00:00:00Z",
                    "updatedAt": "2024-01-01T00:00:00Z"
                ]
            ]
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.notes.count == 1)

        // Clear request log
        fake.requestLog.removeAll()

        // Simulate disconnect
        fake.simulateDisconnect()
        try await Task.sleep(nanoseconds: 50_000_000)

        // Simulate reconnect
        fake.simulateConnect()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Verify fresh subscribe and refetch happened
        #expect(fake.didRequest(method: "note.subscribe"))
        #expect(fake.didRequest(method: "note.list"))
    }

    @Test func legacyEventSuppressedWhileLive() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)

        fake.requestResponses["note.subscribe"] = ["subscriptionId": "sub-notes-123"]
        fake.requestResponses["note.list"] = ["notes": []]

        // Start observing events
        await store.startObservingEvents(workspaceId: "ws-test")

        fake.simulateConnect()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Apply snapshot (now live)
        fake.injectSubscriptionPush(
            subscriptionId: "sub-notes-123",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                [
                    "id": "note-1",
                    "title": "Live note",
                    "content": "Content",
                    "tags": [],
                    "isDefault": false,
                    "isArchived": false,
                    "createdAt": "2024-01-01T00:00:00Z",
                    "updatedAt": "2024-01-01T00:00:00Z"
                ]
            ]
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        // Clear request log
        fake.requestLog.removeAll()

        // Inject legacy note.updated event
        fake.injectEvent(method: "event", params: [
            "subscriptionId": "legacy-sub",
            "event": [
                "type": "note:updated",
                "workspaceId": "ws-test",
                "data": ["noteId": "note-1"]
            ]
        ])
        try await Task.sleep(nanoseconds: 50_000_000)

        // Verify no refetch happened (legacy event suppressed while live)
        #expect(!fake.didRequest(method: "note.list"))
    }

    @Test func wrongSubscriptionIdDropped() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)

        fake.requestResponses["note.subscribe"] = ["subscriptionId": "sub-notes-correct"]
        fake.simulateConnect()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Apply snapshot with correct subscriptionId
        fake.injectSubscriptionPush(
            subscriptionId: "sub-notes-correct",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                [
                    "id": "note-1",
                    "title": "Correct",
                    "content": "Content",
                    "tags": [],
                    "isDefault": false,
                    "isArchived": false,
                    "createdAt": "2024-01-01T00:00:00Z",
                    "updatedAt": "2024-01-01T00:00:00Z"
                ]
            ]
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.notes.count == 1)
        #expect(store.notes[0].title == "Correct")

        // Inject push with wrong subscriptionId
        fake.injectSubscriptionPush(
            subscriptionId: "sub-notes-WRONG",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                [
                    "id": "note-2",
                    "title": "Wrong channel",
                    "content": "Should be dropped",
                    "tags": [],
                    "isDefault": false,
                    "isArchived": false,
                    "createdAt": "2024-01-02T00:00:00Z",
                    "updatedAt": "2024-01-02T00:00:00Z"
                ]
            ]
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        // Verify state unchanged (wrong subscriptionId dropped)
        #expect(store.notes.count == 1)
        #expect(store.notes[0].title == "Correct")
    }
}
