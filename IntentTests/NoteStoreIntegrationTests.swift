import Combine
import Foundation
@testable import Intent
import Testing

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

        // Fetch notes establishes workspace context; the connect observer then
        // subscribes from its own task.
        await store.fetchNotes(workspaceId: "ws-1")
        try await waitUntil("note.subscribe handler registration") {
            fake.hasSubscriptionHandler(id: "sub-1")
        }

        // Verify subscribe was called
        #expect(fake.didCallMethod("note.subscribe"))

        // Deliver snapshot push to make the store live (applied synchronously)
        let push = SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                ["id": "note-1", "title": "Note 1", "content": "", "workspaceId": "ws-1", "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
            ],
            delta: nil
        )
        fake.deliverSubscriptionPush(push)

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
        try await waitUntil("note.subscribe handler registration") {
            fake.hasSubscriptionHandler(id: "sub-1")
        }

        // Snapshot
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                ["id": "note-1", "title": "Note 1", "content": "", "workspaceId": "ws-1", "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
            ],
            delta: nil
        ))
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
        try await waitUntil("note.subscribe handler registration") {
            fake.hasSubscriptionHandler(id: "sub-1")
        }

        // Snapshot
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                ["id": "note-1", "title": "Note 1", "content": "", "workspaceId": "ws-1", "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
            ],
            delta: nil
        ))
        #expect(store.notes.count == 1)

        fake.clearRequestLog()

        // Gap (seq 5 instead of 1) triggers resnapshot
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .delta,
            seq: 5,
            snapshot: nil,
            delta: SubscriptionPush.DeltaPayload(added: [], updated: [], removedIds: [])
        ))
        // The baseline `note.list` is the last step of resnapshot, so its
        // arrival proves unsubscribe and subscribe already ran.
        try await fake.waitForRequests("note.list")

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
        try await waitUntil("note.subscribe handler registration") {
            fake.hasSubscriptionHandler(id: "sub-1")
        }

        // Snapshot
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                ["id": "note-1", "title": "Note 1", "content": "", "workspaceId": "ws-1", "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
            ],
            delta: nil
        ))
        #expect(store.notes.count == 1)

        // Disconnect, then reconnect with a fresh subscription id so the
        // resubscribe is distinguishable from the original registration.
        fake.responseMap["note.subscribe"] = ["subscriptionId": "sub-2", "seq": 0, "snapshot": []]
        fake.clearRequestLog()
        fake.simulateDisconnect()
        fake.simulateConnect()
        try await waitUntil("reconnect resubscribe") {
            fake.hasSubscriptionHandler(id: "sub-2")
        }

        // Verify fresh subscribe + list
        #expect(fake.didCallMethod("note.subscribe"))
        #expect(fake.didCallMethod("note.list"))
        #expect(!fake.hasSubscriptionHandler(id: "sub-1"))
    }

    // MARK: - legacyEventSuppressedWhileLive

    @Test func legacyEventSuppressedWhileLive() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)

        fake.responseMap["note.list"] = ["notes": []]
        fake.responseMap["note.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.simulateConnect()
        await store.fetchNotes(workspaceId: "ws-1")
        try await waitUntil("note.subscribe handler registration") {
            fake.hasSubscriptionHandler(id: "sub-1")
        }

        // Snapshot establishes live state
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                ["id": "note-1", "title": "Note 1", "content": "", "workspaceId": "ws-1", "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
            ],
            delta: nil
        ))
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

        // Verify no refetch (legacy event suppressed)
        try await expectNever("note.list refetch while live") {
            fake.didCallMethod("note.list")
        }
    }

    // MARK: - crossIdPushIsolation

    @Test func crossIdPushIsolation() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)

        fake.responseMap["note.list"] = ["notes": []]
        fake.responseMap["note.subscribe"] = ["subscriptionId": "sub-A", "seq": 0, "snapshot": []]
        fake.simulateConnect()
        await store.fetchNotes(workspaceId: "ws-1")
        try await waitUntil("note.subscribe handler registration") {
            fake.hasSubscriptionHandler(id: "sub-A")
        }

        // Snapshot for sub-A
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-A",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                ["id": "note-1", "title": "Note 1", "content": "", "workspaceId": "ws-1", "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
            ],
            delta: nil
        ))
        #expect(store.notes.count == 1)

        // Push for unregistered sub-B (should be ignored by store)
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-B",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                ["id": "note-99", "title": "Should not appear", "content": "", "workspaceId": "ws-1", "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
            ],
            delta: nil
        ))

        // Verify state unchanged
        #expect(store.notes.count == 1)
        #expect(store.notes[0].id == "note-1")
        #expect(!fake.hasSubscriptionHandler(id: "sub-B"))
    }
}
