import Foundation
import Testing
@testable import Intent

@MainActor
struct TaskStoreLiveStateTests {
    
    @Test func appliesSnapshot() async throws {
        let store = TaskStore(workspaceId: "ws-test")

        let push = SubscriptionPush(
            subscriptionId: "sub-123",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                ["id": "task-1", "title": "Task 1", "status": "not_started", "updatedAt": "2026-07-17T12:00:00Z"],
                ["id": "task-2", "title": "Task 2", "status": "in_progress", "updatedAt": "2026-07-17T12:01:00Z"]
            ],
            delta: nil
        )

        // Directly initialize reconciler and apply push (simulating what subscribeLiveState does)
        let reconciler = DeltaReconciler<WorkspaceTask>(
            getId: { dict in dict["id"] as? String },
            normalize: { dict in WorkspaceTask.parseTask(dict) }
        )
        reconciler.applySnapshot(seq: push.seq, rawItems: push.snapshot!)

        let values = reconciler.values()
        #expect(values.count == 2)
        #expect(values[0].id == "task-1")
        #expect(values[0].title == "Task 1")
        #expect(values[0].status == "not_started")
        #expect(values[1].id == "task-2")
        #expect(values[1].title == "Task 2")
        #expect(values[1].status == "in_progress")
    }
    
    @Test func appliesContiguousDelta() async throws {
        let reconciler = DeltaReconciler<WorkspaceTask>(
            getId: { dict in dict["id"] as? String },
            normalize: { dict in WorkspaceTask.parseTask(dict) }
        )
        
        // Start with snapshot
        let snapshot = [
            ["id": "task-1", "title": "Task 1", "status": "not_started", "updatedAt": "2026-07-17T12:00:00Z"],
            ["id": "task-2", "title": "Task 2", "status": "in_progress", "updatedAt": "2026-07-17T12:01:00Z"]
        ]
        reconciler.applySnapshot(seq: 0, rawItems: snapshot)
        
        // Apply contiguous delta (seq 1)
        let delta = SubscriptionPush.DeltaPayload(
            added: [["id": "task-3", "title": "Task 3", "status": "complete", "updatedAt": "2026-07-17T12:02:00Z"]],
            updated: [["id": "task-1", "title": "Task 1 Updated", "status": "in_progress", "updatedAt": "2026-07-17T12:03:00Z"]],
            removedIds: ["task-2"]
        )
        let success = reconciler.applyDelta(seq: 1, delta: delta)
        
        #expect(success == true)
        let values = reconciler.values()
        #expect(values.count == 2)
        #expect(values[0].id == "task-1")
        #expect(values[0].title == "Task 1 Updated")
        #expect(values[0].status == "in_progress")
        #expect(values[1].id == "task-3")
        #expect(values[1].status == "complete")
    }
    
    @Test func detectsGapAndReturnsFalse() async throws {
        let reconciler = DeltaReconciler<WorkspaceTask>(
            getId: { dict in dict["id"] as? String },
            normalize: { dict in WorkspaceTask.parseTask(dict) }
        )
        
        // Start with snapshot
        reconciler.applySnapshot(seq: 0, rawItems: [
            ["id": "task-1", "title": "Task 1", "status": "not_started", "updatedAt": "2026-07-17T12:00:00Z"]
        ])
        
        // Try to apply delta with gap (expected seq 1, got seq 5)
        let delta = SubscriptionPush.DeltaPayload(
            added: [["id": "task-2", "title": "Task 2", "status": "not_started", "updatedAt": "2026-07-17T12:01:00Z"]],
            updated: [],
            removedIds: []
        )
        let success = reconciler.applyDelta(seq: 5, delta: delta)
        
        #expect(success == false)
    }
    
    @Test func resetsOnReconnect() async throws {
        let reconciler = DeltaReconciler<WorkspaceTask>(
            getId: { dict in dict["id"] as? String },
            normalize: { dict in WorkspaceTask.parseTask(dict) }
        )
        
        // Apply snapshot
        reconciler.applySnapshot(seq: 0, rawItems: [
            ["id": "task-1", "title": "Task 1", "status": "not_started", "updatedAt": "2026-07-17T12:00:00Z"]
        ])
        #expect(reconciler.values().count == 1)
        
        // Simulate reconnect by resetting
        reconciler.reset()
        #expect(reconciler.values().count == 0)
        
        // Delta should fail after reset (not seeded)
        let delta = SubscriptionPush.DeltaPayload(
            added: [["id": "task-2", "title": "Task 2", "status": "not_started", "updatedAt": "2026-07-17T12:01:00Z"]],
            updated: [],
            removedIds: []
        )
        let success = reconciler.applyDelta(seq: 1, delta: delta)
        #expect(success == false)
    }
    
    @Test func rejectsMalformedPush() async throws {
        // Snapshot push missing "snapshot" field
        let snapshotMissingPayload: [String: Any] = [
            "subscriptionId": "sub-1",
            "kind": "snapshot",
            "seq": 0
        ]
        let push1 = SubscriptionPush.parse(method: "subscription.push", params: snapshotMissingPayload)
        #expect(push1 == nil)
        
        // Delta push missing "delta" field
        let deltaMissingPayload: [String: Any] = [
            "subscriptionId": "sub-1",
            "kind": "delta",
            "seq": 1
        ]
        let push2 = SubscriptionPush.parse(method: "subscription.push", params: deltaMissingPayload)
        #expect(push2 == nil)
    }
}
