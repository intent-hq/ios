import Foundation
@testable import Intent
import Testing

/// Paged subscription snapshots (PROTOCOL §6.9): the snapshot push carries
/// `nextToken`, later pages merge under the deltas that arrived meanwhile.
@MainActor
struct DeltaReconcilerPagingTests {
    private struct PageRow: Equatable {
        let id: String
        let title: String
    }

    private static func makeReconciler() -> DeltaReconciler<PageRow> {
        DeltaReconciler<PageRow>(
            getId: { $0["id"] as? String },
            normalize: { raw in
                guard let id = raw["id"] as? String, let title = raw["title"] as? String else { return nil }
                return PageRow(id: id, title: title)
            }
        )
    }

    private static func row(_ id: String, _ title: String) -> [String: Any] {
        ["id": id, "title": title]
    }

    @Test func parsesSnapshotNextToken() throws {
        let push = try #require(SubscriptionPush.parse(method: "subscription.push", params: [
            "subscriptionId": "sub-1", "kind": "snapshot", "seq": 0,
            "snapshot": [Self.row("a", "A")], "nextToken": "page-2"
        ] as [String: Any]))
        #expect(push.nextToken == "page-2")
    }

    @Test(arguments: [true, false])
    func treatsNullOrEmptyNextTokenAsWhole(sendsNull: Bool) throws {
        let token: Any = sendsNull ? NSNull() : ""
        let push = try #require(SubscriptionPush.parse(method: "subscription.push", params: [
            "subscriptionId": "sub-1", "kind": "snapshot", "seq": 0,
            "snapshot": [Self.row("a", "A")], "nextToken": token
        ] as [String: Any]))
        #expect(push.nextToken == nil)
    }

    @Test func snapshotWithoutNextTokenStaysWhole() throws {
        let push = try #require(SubscriptionPush.parse(method: "subscription.push", params: [
            "subscriptionId": "sub-1", "kind": "snapshot", "seq": 0, "snapshot": [[String: Any]]()
        ] as [String: Any]))
        #expect(push.nextToken == nil)
    }

    @Test func fillFromPageAppendsLaterPages() {
        let reconciler = Self.makeReconciler()
        reconciler.applySnapshot(seq: 0, rawItems: [Self.row("a", "A")])
        reconciler.fillFromPage([Self.row("b", "B"), Self.row("c", "C")])
        reconciler.fillFromPage([])
        #expect(reconciler.values().map(\.id) == ["a", "b", "c"])
    }

    @Test func pageRowsNeverOverrideNewerDeltas() {
        let reconciler = Self.makeReconciler()
        reconciler.applySnapshot(seq: 0, rawItems: [Self.row("a", "A")])
        let delta = SubscriptionPush.DeltaPayload(
            added: [Self.row("b", "B from delta")],
            updated: [Self.row("a", "A from delta")],
            removedIds: ["c"]
        )
        #expect(reconciler.applyDelta(seq: 1, delta: delta))
        reconciler.fillFromPage([Self.row("a", "A stale"), Self.row("b", "B stale"), Self.row("c", "C stale")])
        #expect(reconciler.values() == [PageRow(id: "a", title: "A from delta"), PageRow(id: "b", title: "B from delta")])
    }

    @Test func pageRowsNeverOverrideLocalSeeds() {
        let reconciler = Self.makeReconciler()
        reconciler.applySnapshot(seq: 0, rawItems: [])
        reconciler.seed(id: "a", value: PageRow(id: "a", title: "Optimistic"))
        reconciler.fillFromPage([Self.row("a", "Page")])
        #expect(reconciler.values() == [PageRow(id: "a", title: "Optimistic")])
    }

    @Test func aRowServedAgainKeepsTheLaterCopy() {
        // comment.list rounds can serve a thread twice; the later row is newer.
        let reconciler = Self.makeReconciler()
        reconciler.applySnapshot(seq: 0, rawItems: [Self.row("t-1", "old")])
        reconciler.fillFromPage([Self.row("t-2", "two"), Self.row("t-1", "new")])
        #expect(reconciler.values() == [PageRow(id: "t-1", title: "new"), PageRow(id: "t-2", title: "two")])
    }

    @Test func snapshotAndResetBumpTheEpochAndClearPageGuards() {
        let reconciler = Self.makeReconciler()
        let start = reconciler.epoch
        reconciler.applySnapshot(seq: 0, rawItems: [])
        #expect(reconciler.applyDelta(seq: 1, delta: .init(added: [], updated: [], removedIds: ["a"])))
        #expect(reconciler.epoch == start + 1)
        reconciler.applySnapshot(seq: 5, rawItems: [])
        #expect(reconciler.epoch == start + 2)
        // A new snapshot forgets the old removal, so its own pages may add the row.
        reconciler.fillFromPage([Self.row("a", "A")])
        #expect(reconciler.values().map(\.id) == ["a"])
        reconciler.reset()
        #expect(reconciler.epoch == start + 3)
        #expect(reconciler.values().isEmpty)
    }
}
