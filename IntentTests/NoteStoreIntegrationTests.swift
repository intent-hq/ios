import Combine
import Foundation
@testable import Intent
import Testing

@MainActor
struct NoteStoreIntegrationTests {
    @Test func subscribeOnConnect() async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)

        fake.responseMap["note.list"] = ["notes": []]
        fake.responseMap["note.subscribe"] = [
            "subscriptionId": "sub-1",
            "seq": 0,
            "snapshot": []
        ]

        fake.simulateConnect()

        await store.fetchNotes(workspaceId: "ws-1")
        try await waitUntil("note.subscribe handler registration") {
            fake.hasSubscriptionHandler(id: "sub-1")
        }

        #expect(fake.didCallMethod("note.subscribe"))

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

        #expect(store.notes.count == 1)
    }

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

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .delta,
            seq: 5,
            snapshot: nil,
            delta: SubscriptionPush.DeltaPayload(added: [], updated: [], removedIds: [])
        ))
        try await fake.waitForRequests("note.list")

        #expect(fake.didCallMethod("note.unsubscribe"))
        #expect(fake.didCallMethod("note.subscribe"))
        #expect(fake.didCallMethod("note.list"))
    }

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

        fake.responseMap["note.subscribe"] = ["subscriptionId": "sub-2", "seq": 0, "snapshot": []]
        fake.clearRequestLog()
        fake.simulateDisconnect()
        fake.simulateConnect()
        try await waitUntil("reconnect resubscribe") {
            fake.hasSubscriptionHandler(id: "sub-2")
        }

        #expect(fake.didCallMethod("note.subscribe"))
        #expect(fake.didCallMethod("note.list"))
        #expect(!fake.hasSubscriptionHandler(id: "sub-1"))
    }

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

        fake.deliverEvent(method: "note.updated", params: [
            "event": [
                "type": "note:updated",
                "workspaceId": "ws-1",
                "noteId": "note-1"
            ]
        ])

        try await expectNever("note.list refetch while live") {
            fake.didCallMethod("note.list")
        }
    }

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

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-B",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                ["id": "note-99", "title": "Should not appear", "content": "", "workspaceId": "ws-1", "createdAt": "2024-01-01T00:00:00Z", "updatedAt": "2024-01-01T00:00:00Z"]
            ],
            delta: nil
        ))

        #expect(store.notes.count == 1)
        #expect(store.notes[0].id == "note-1")
        #expect(!fake.hasSubscriptionHandler(id: "sub-B"))
    }
}
