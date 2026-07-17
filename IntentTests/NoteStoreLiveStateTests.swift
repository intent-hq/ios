import Foundation
import Testing
@testable import Intent

@MainActor
struct NoteStoreLiveStateTests {
    
    // MARK: - Snapshot tests
    
    @Test func appliesSnapshot() async throws {
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
           let snapshot = push.snapshot {
            reconciler.applySnapshot(seq: push.seq, rawItems: snapshot)
            let notes = reconciler.values()
            
            #expect(notes.count == 2)
            #expect(notes[0].id == "note-1")
            #expect(notes[1].id == "note-2")
        } else {
            Issue.record("Failed to parse snapshot push")
        }
    }
    
    @Test func appliesContiguousDelta() async throws {
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
            updated: [[
                "id": "note-1",
                "title": "First Updated",
                "content": "Updated content",
                "tags": ["new-tag"],
                "isDefault": false,
                "isArchived": false,
                "createdAt": "2024-01-01T00:00:00Z",
                "updatedAt": "2024-01-01T01:00:00Z"
            ]],
            removedIds: []
        )
        
        let success = reconciler.applyDelta(seq: 1, delta: delta)
        #expect(success == true)
        
        let notes = reconciler.values()
        #expect(notes.count == 2)
        #expect(notes[0].title == "First Updated")
        #expect(notes[1].id == "note-2")
    }
    
    @Test func detectsGapAndReturnsFalse() async throws {
        let reconciler = DeltaReconciler<Note>(
            getId: { dict in dict["id"] as? String },
            normalize: { dict in Note.parseNote(dict) }
        )
        
        // Start with snapshot
        reconciler.applySnapshot(seq: 0, rawItems: [[
            "id": "note-1",
            "title": "First",
            "content": "Content",
            "tags": [],
            "isDefault": false,
            "isArchived": false,
            "createdAt": "2024-01-01T00:00:00Z",
            "updatedAt": "2024-01-01T00:00:00Z"
        ]])
        
        // Try to apply delta with gap (expected seq 1, but got 5)
        let delta = SubscriptionPush.DeltaPayload(
            added: [],
            updated: [],
            removedIds: []
        )
        let success = reconciler.applyDelta(seq: 5, delta: delta)

        #expect(success == false)
    }

    @Test func reconcilerResets() async throws {
        let reconciler = DeltaReconciler<Note>(
            getId: { dict in dict["id"] as? String },
            normalize: { dict in Note.parseNote(dict) }
        )

        // Start with snapshot
        reconciler.applySnapshot(seq: 0, rawItems: [[
            "id": "note-1",
            "title": "First",
            "content": "Content",
            "tags": [],
            "isDefault": false,
            "isArchived": false,
            "createdAt": "2024-01-01T00:00:00Z",
            "updatedAt": "2024-01-01T00:00:00Z"
        ]])

        #expect(reconciler.values().count == 1)

        // Simulate reconnect by resetting
        reconciler.reset()

        #expect(reconciler.values().count == 0)

        // Delta should fail after reset (not seeded)
        let delta = SubscriptionPush.DeltaPayload(added: [], updated: [], removedIds: [])
        let success = reconciler.applyDelta(seq: 1, delta: delta)
        #expect(success == false)
    }

    @Test func rejectsMalformedPush() async throws {
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
