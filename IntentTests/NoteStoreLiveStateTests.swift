import Foundation
@testable import Intent
import Testing

@MainActor
struct NoteStoreLiveStateTests {
    @Test(arguments: [false, true])
    func queuedConnectionDeliveryCannotReviveSuspendedNotes(resumedObserver: Bool) async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        store.startObservingEvents(workspaceId: "ws-1")
        fake.responseMap["note.list"] = ["notes": []]
        fake.responseMap["note.subscribe"] = ["subscriptionId": "returned-sub"]
        if resumedObserver {
            store.suspendObservation()
            store.resumeObservation(workspaceId: "ws-1")
        }

        // receive(on:) has queued the connected emission, but cannot deliver it
        // until this main-actor turn ends. Suspend before that delivery.
        fake.simulateConnect()
        store.suspendObservation()
        let suspendedGeneration = store.liveSubscriptionGeneration
        try await expectNever("offscreen note work", within: .milliseconds(100)) {
            fake.didCallMethod("note.list") || fake.didCallMethod("note.subscribe")
        }
        #expect(store.liveSubscriptionGeneration == suspendedGeneration)
        #expect(store.liveSubscription == .idle)

        // A further reconnect while offscreen must not leave a stale live
        // subscription that causes resume to skip installing a new handler.
        fake.simulateDisconnect()
        fake.simulateConnect()
        store.resumeObservation(workspaceId: "ws-1")
        try await waitUntil("returned note subscription") { fake.hasSubscriptionHandler(id: "returned-sub") }
        let snapshot = try #require(SubscriptionPush.parse(method: "subscription.push", params: [
            "subscriptionId": "returned-sub", "kind": "snapshot", "seq": 0,
            "snapshot": [["id": "n-1", "title": "Returned", "content": "", "createdAt": "", "updatedAt": ""]]
        ]))
        fake.deliverSubscriptionPush(snapshot)
        #expect(store.notes.first?.title == "Returned")
        let delta = try #require(SubscriptionPush.parse(method: "subscription.push", params: [
            "subscriptionId": "returned-sub", "kind": "delta", "seq": 1,
            "delta": [
                "added": [],
                "updated": [
                    ["id": "n-1", "title": "Edited later", "content": "", "createdAt": "", "updatedAt": "later"]
                ],
                "removedIds": []
            ]
        ]))
        fake.deliverSubscriptionPush(delta)
        #expect(store.notes.first?.title == "Edited later")
    }

    @Test(arguments: [false, true], [false, true])
    func scheduledReconnectCannotOutliveItsObserver(resumedObserver: Bool, reactivate: Bool) async throws {
        let fake = FakeConnectionManager()
        let store = NoteStore(connectionManager: fake)
        store.startObservingEvents(workspaceId: "ws-1")
        fake.responseMap["note.list"] = ["notes": []]
        fake.responseMap["note.subscribe"] = ["subscriptionId": "returned-sub"]
        if resumedObserver {
            store.suspendObservation()
            store.resumeObservation(workspaceId: "ws-1")
        }
        fake.simulateConnect()
        // Exercise the exact task scheduled by the observer, with suspension
        // and reactivation before the task gets a chance to start.
        let queuedReconnect = store.scheduleReconnect()
        store.suspendObservation()
        if !reactivate {
            let suspendedGeneration = store.liveSubscriptionGeneration
            await queuedReconnect.value
            #expect(store.liveSubscriptionGeneration == suspendedGeneration)
            #expect(!fake.didCallMethod("note.list"))
            #expect(!fake.didCallMethod("note.subscribe"))
            return
        }
        store.resumeObservation(workspaceId: "ws-1")
        let resumedGeneration = store.liveSubscriptionGeneration
        await queuedReconnect.value
        try await waitUntil("returned subscription") { fake.hasSubscriptionHandler(id: "returned-sub") }
        #expect(store.liveSubscriptionGeneration == resumedGeneration)
        try await expectNever("stale reconnect refetch", within: .milliseconds(100)) {
            fake.didCallMethod("note.list")
        }
        #expect(fake.requestLog.filter { $0.method == "note.subscribe" }.count == 1)
    }

    // MARK: - Snapshot tests

    @Test func appliesSnapshot() {
        // Simulate subscription.push snapshot
        let params: [String: Any] = [
            "subscriptionId": "sub-notes-123",
            "kind": "snapshot",
            "seq": 0,
            "snapshot": [
                [
                    "id": "note-1",
                    "title": "First Note",
                    "content": "Content 1",
                    "tags": [],
                    "isDefault": false,
                    "isArchived": false,
                    "createdAt": "2024-01-01T00:00:00Z",
                    "updatedAt": "2024-01-01T00:00:00Z"
                ],
                [
                    "id": "note-2",
                    "title": "Second Note",
                    "content": "Content 2",
                    "tags": ["tag1"],
                    "isDefault": false,
                    "isArchived": false,
                    "createdAt": "2024-01-02T00:00:00Z",
                    "updatedAt": "2024-01-02T00:00:00Z"
                ]
            ]
        ]

        // Set up reconciler (normally done by subscribeLiveState)
        let reconciler = DeltaReconciler<Note>(
            getId: { dict in dict["id"] as? String },
            normalize: { dict in Note.parseNote(dict) }
        )

        if let push = SubscriptionPush.parse(method: "subscription.push", params: params),
           case let .collectionSnapshot(snapshot) = push.payload {
            reconciler.applySnapshot(seq: push.seq, rawItems: snapshot)
            let notes = reconciler.values()

            #expect(notes.count == 2)
            #expect(notes[0].id == "note-1")
            #expect(notes[1].id == "note-2")
        } else {
            Issue.record("Failed to parse snapshot push")
        }
    }

    @Test func appliesContiguousDelta() {
        let reconciler = DeltaReconciler<Note>(
            getId: { dict in dict["id"] as? String },
            normalize: { dict in Note.parseNote(dict) }
        )

        // Start with snapshot
        let snapshot = [
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
        reconciler.applySnapshot(seq: 0, rawItems: snapshot)

        // Apply contiguous delta
        let delta = SubscriptionPush.DeltaPayload(
            added: [
                [
                    "id": "note-2",
                    "title": "Second",
                    "content": "Content 2",
                    "tags": [],
                    "isDefault": false,
                    "isArchived": false,
                    "createdAt": "2024-01-02T00:00:00Z",
                    "updatedAt": "2024-01-02T00:00:00Z"
                ]
            ],
            updated: [
                [
                    "id": "note-1",
                    "title": "First Updated",
                    "content": "Updated content",
                    "tags": ["new-tag"],
                    "isDefault": false,
                    "isArchived": false,
                    "createdAt": "2024-01-01T00:00:00Z",
                    "updatedAt": "2024-01-01T01:00:00Z"
                ]
            ],
            removedIds: []
        )

        let success = reconciler.applyDelta(seq: 1, delta: delta)
        #expect(success == true)

        let notes = reconciler.values()
        #expect(notes.count == 2)
        #expect(notes[0].title == "First Updated")
        #expect(notes[1].id == "note-2")
    }

    @Test func detectsGapAndReturnsFalse() {
        let reconciler = DeltaReconciler<Note>(
            getId: { dict in dict["id"] as? String },
            normalize: { dict in Note.parseNote(dict) }
        )

        // Start with snapshot
        reconciler.applySnapshot(
            seq: 0,
            rawItems: [
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

        // Try to apply delta with gap (expected seq 1, but got 5)
        let delta = SubscriptionPush.DeltaPayload(
            added: [],
            updated: [],
            removedIds: []
        )
        let success = reconciler.applyDelta(seq: 5, delta: delta)

        #expect(success == false)
    }

    @Test func reconcilerResets() {
        let reconciler = DeltaReconciler<Note>(
            getId: { dict in dict["id"] as? String },
            normalize: { dict in Note.parseNote(dict) }
        )

        // Start with snapshot
        reconciler.applySnapshot(
            seq: 0,
            rawItems: [
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

        #expect(reconciler.values().count == 1)

        // Simulate reconnect by resetting
        reconciler.reset()

        #expect(reconciler.values().isEmpty)

        // Delta should fail after reset (not seeded)
        let delta = SubscriptionPush.DeltaPayload(added: [], updated: [], removedIds: [])
        let success = reconciler.applyDelta(seq: 1, delta: delta)
        #expect(success == false)
    }

    @Test func rejectsMalformedPush() {
        // Snapshot push missing "snapshot" field
        let malformedSnapshot: [String: Any] = [
            "subscriptionId": "sub-1",
            "kind": "snapshot",
            "seq": 0
        ]
        let push1 = SubscriptionPush.parse(method: "subscription.push", params: malformedSnapshot)
        #expect(push1 == nil)

        // Delta push missing "delta" field
        let malformedDelta: [String: Any] = [
            "subscriptionId": "sub-1",
            "kind": "delta",
            "seq": 1
        ]
        let push2 = SubscriptionPush.parse(method: "subscription.push", params: malformedDelta)
        #expect(push2 == nil)

        // Missing required fields
        let incomplete: [String: Any] = [
            "kind": "snapshot"
        ]
        let push3 = SubscriptionPush.parse(method: "subscription.push", params: incomplete)
        #expect(push3 == nil)
    }
}
