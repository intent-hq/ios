import Foundation
import Testing
@testable import Intent

struct DeltaSubscriptionTests {
    
    // MARK: - SubscriptionPush parsing
    
    @Test func parseSnapshotPush() async throws {
        let params: [String: Any] = [
            "subscriptionId": "sub-123",
            "kind": "snapshot",
            "seq": 0,
            "snapshot": [
                ["id": "ws-1", "title": "Workspace 1"],
                ["id": "ws-2", "title": "Workspace 2"]
            ]
        ]
        
        let push = SubscriptionPush.parse(method: "subscription.push", params: params)
        #expect(push != nil)
        #expect(push?.subscriptionId == "sub-123")
        #expect(push?.seq == 0)
        #expect(push?.snapshot?.count == 2)
    }
    
    @Test func parseDeltaPush() async throws {
        let params: [String: Any] = [
            "subscriptionId": "sub-123",
            "kind": "delta",
            "seq": 1,
            "delta": [
                "added": [["id": "ws-3", "title": "New"]],
                "updated": [["id": "ws-1", "title": "Updated"]],
                "removedIds": ["ws-2"]
            ]
        ]
        
        let push = SubscriptionPush.parse(method: "subscription.push", params: params)
        #expect(push != nil)
        #expect(push?.subscriptionId == "sub-123")
        #expect(push?.seq == 1)
        #expect(push?.delta?.added.count == 1)
        #expect(push?.delta?.updated.count == 1)
        #expect(push?.delta?.removedIds.count == 1)
    }
    
    @Test func parseNonPushMethodReturnsNil() async throws {
        let params: [String: Any] = ["foo": "bar"]
        let push = SubscriptionPush.parse(method: "other.method", params: params)
        #expect(push == nil)
    }
    
    @Test func parseMalformedPushReturnsNil() async throws {
        let params: [String: Any] = ["kind": "snapshot"] // missing subscriptionId and seq
        let push = SubscriptionPush.parse(method: "subscription.push", params: params)
        #expect(push == nil)

        // Snapshot push missing "snapshot" field
        let snapshotMissingPayload: [String: Any] = [
            "subscriptionId": "sub-1",
            "kind": "snapshot",
            "seq": 0
        ]
        #expect(SubscriptionPush.parse(method: "subscription.push", params: snapshotMissingPayload) == nil)

        // Delta push missing "delta" field
        let deltaMissingPayload: [String: Any] = [
            "subscriptionId": "sub-1",
            "kind": "delta",
            "seq": 1
        ]
        #expect(SubscriptionPush.parse(method: "subscription.push", params: deltaMissingPayload) == nil)
    }
    
    // MARK: - DeltaReconciler
    
    @Test func reconcilerSnapshot() async throws {
        let reconciler = DeltaReconciler<[String: Any]>(
            getId: { $0["id"] as? String },
            normalize: { $0 }
        )
        
        let items = [
            ["id": "1", "name": "One"],
            ["id": "2", "name": "Two"]
        ]
        reconciler.applySnapshot(seq: 0, rawItems: items)
        
        let values = reconciler.values()
        #expect(values.count == 2)
    }
    
    @Test func reconcilerDelta() async throws {
        let reconciler = DeltaReconciler<[String: Any]>(
            getId: { $0["id"] as? String },
            normalize: { $0 }
        )
        
        // Start with snapshot
        let snapshot = [
            ["id": "1", "name": "One"],
            ["id": "2", "name": "Two"]
        ]
        reconciler.applySnapshot(seq: 0, rawItems: snapshot)
        
        // Apply delta
        let delta = SubscriptionPush.DeltaPayload(
            added: [["id": "3", "name": "Three"]],
            updated: [["id": "1", "name": "One Updated"]],
            removedIds: ["2"]
        )
        let success = reconciler.applyDelta(seq: 1, delta: delta)
        
        #expect(success == true)
        let values = reconciler.values()
        #expect(values.count == 2) // 1 (updated) + 3 (added), 2 removed
    }
    
    @Test func reconcilerDeltaGapDetection() async throws {
        let reconciler = DeltaReconciler<[String: Any]>(
            getId: { $0["id"] as? String },
            normalize: { $0 }
        )
        
        // Start with snapshot
        reconciler.applySnapshot(seq: 0, rawItems: [["id": "1", "name": "One"]])
        
        // Try to apply delta with wrong seq (gap)
        let delta = SubscriptionPush.DeltaPayload(added: [["id": "2", "name": "Two"]], updated: [], removedIds: [])
        let success = reconciler.applyDelta(seq: 5, delta: delta) // Expected 1, got 5
        
        #expect(success == false)
    }
    
    @Test func reconcilerDeltaBeforeSnapshotFails() async throws {
        let reconciler = DeltaReconciler<[String: Any]>(
            getId: { $0["id"] as? String },
            normalize: { $0 }
        )
        
        // Try to apply delta without snapshot (not seeded)
        let delta = SubscriptionPush.DeltaPayload(added: [["id": "1", "name": "One"]], updated: [], removedIds: [])
        let success = reconciler.applyDelta(seq: 1, delta: delta)
        
        #expect(success == false)
    }
    
    @Test func reconcilerReset() async throws {
        let reconciler = DeltaReconciler<[String: Any]>(
            getId: { $0["id"] as? String },
            normalize: { $0 }
        )
        
        reconciler.applySnapshot(seq: 0, rawItems: [["id": "1", "name": "One"]])
        #expect(reconciler.values().count == 1)
        
        reconciler.reset()
        #expect(reconciler.values().count == 0)
        
        // After reset, delta should fail (not seeded)
        let delta = SubscriptionPush.DeltaPayload(added: [["id": "2", "name": "Two"]], updated: [], removedIds: [])
        let success = reconciler.applyDelta(seq: 1, delta: delta)
        #expect(success == false)
    }
}
