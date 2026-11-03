import Foundation
@testable import Intent
import Testing

/// WorkspaceStore against a bounded daemon (protocol "Paged workspace lists"
/// and §6.9 "Paged snapshots"). A workspace missing from a loaded list reads
/// as deleted, so a partial list must never be published.
@MainActor
struct WorkspaceStorePagingTests {
    private struct PageError: Error {}

    private static func workspaces(_ range: ClosedRange<Int>) -> [[String: Any]] {
        range.map { ["id": "ws-\($0)", "title": "Workspace \($0)"] }
    }

    @Test func fetchAllReadsEveryPage() async {
        let fake = FakeConnectionManager()
        let store = WorkspaceStore(connectionManager: fake)
        fake.responseQueueMap["workspace.list"] = [
            ["workspaces": Self.workspaces(1...200), "nextToken": "t1"],
            // A non-administrator page can hold no rows and still continue.
            ["workspaces": [[String: Any]](), "nextToken": "t2"],
            ["workspaces": Self.workspaces(201...250), "nextToken": NSNull()]
        ]

        await store.fetchAll()

        #expect(store.workspaces.count == 250)
        #expect(store.lastUpdated != nil)
        let sent = fake.paramsForMethod("workspace.list")
        #expect(sent.map { $0["nextToken"] as? String } == [nil, "t1", "t2"])
        #expect(sent.allSatisfy { params in
            params["includeArchived"] as? Bool == true && params["limit"] as? Int == PagedReads.workspacePageLimit
        })
    }

    @Test func fetchAllNeverPublishesAPartialList() async {
        let fake = FakeConnectionManager()
        let store = WorkspaceStore(connectionManager: fake)
        fake.pendingMethods = ["workspace.list"]
        let fetch = Task { await store.fetchAll() }
        try? await fake.waitForPendingRequests("workspace.list")
        fake.resolvePending("workspace.list", with: ["workspaces": Self.workspaces(1...200), "nextToken": "t1"] as [String: Any])
        try? await fake.waitForPendingRequests("workspace.list")
        fake.failPending("workspace.list", with: URLError(.networkConnectionLost))
        await fetch.value

        #expect(store.workspaces.isEmpty)
        #expect(store.lastUpdated == nil)
    }

    @Test func fetchAllAcceptsAnUnpagedBareArray() async {
        let fake = FakeConnectionManager()
        let store = WorkspaceStore(connectionManager: fake)
        fake.responseMap["workspace.list"] = Self.workspaces(1...3)
        await store.fetchAll()
        #expect(store.workspaces.count == 3)
        #expect(fake.paramsForMethod("workspace.list").count == 1)
    }

    @Test func fetchAllThatCannotFinishKeepsThePreviousList() async {
        let fake = FakeConnectionManager()
        let store = WorkspaceStore(connectionManager: fake)
        fake.responseMap["workspace.list"] = ["workspaces": Self.workspaces(1...3), "nextToken": NSNull()]
        await store.fetchAll()
        #expect(store.workspaces.count == 3)

        // The daemon repeats its token, so the walk cannot reach the last page.
        fake.responseMap["workspace.list"] = ["workspaces": Self.workspaces(1...2), "nextToken": "same"]
        await store.fetchAll()
        #expect(store.workspaces.count == 3)
    }

    /// Connected store with a complete 150-workspace list and a registered
    /// `workspace.subscribe` handler (`sub-1`).
    private func liveStore() async throws -> (WorkspaceStore, FakeConnectionManager) {
        let fake = FakeConnectionManager()
        let store = WorkspaceStore(connectionManager: fake)
        store.snapshotFiller.sleep = { _ in }
        fake.responseMap["workspace.list"] = ["workspaces": Self.workspaces(1...150), "nextToken": NSNull()]
        fake.responseMap["workspace.subscribe"] = ["subscriptionId": "sub-1"]
        fake.responseMap["workspace.unsubscribe"] = [:] as [String: Any]
        fake.simulateConnect()
        try await waitUntil("workspace.subscribe handler registration") { fake.hasSubscriptionHandler(id: "sub-1") }
        #expect(store.workspaces.count == 150)
        fake.clearRequestLog()
        return (store, fake)
    }

    @Test func pagedSnapshotKeepsTheWholeListUntilEveryPageIsRead() async throws {
        let (store, fake) = try await liveStore()
        let revisionBefore = store.workspacesRevision
        fake.pendingMethods = ["workspace.list"]

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1", seq: 0, snapshot: Self.workspaces(1...100), nextToken: "t1"
        ))
        try await fake.waitForPendingRequests("workspace.list")
        #expect(store.workspaces.count == 150, "the previous whole list stays while the snapshot fills")

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            seq: 1,
            delta: .init(added: [["id": "ws-151", "title": "New"]], updated: [["id": "ws-120", "title": "Renamed"]], removedIds: [])
        ))
        #expect(store.workspaces.count == 150)
        #expect(store.workspacesRevision == revisionBefore, "nothing is published while the snapshot fills")

        fake.resolvePending("workspace.list", with: [
            "workspaces": Self.workspaces(101...150), "nextToken": NSNull()
        ] as [String: Any])

        try await waitUntil("whole snapshot published") { store.workspaces.count == 151 && !store.snapshotFiller.isFilling }
        #expect(store.workspaces.first { $0.id == "ws-120" }?.title == "Renamed")
        #expect(store.workspacesRevision == revisionBefore &+ 1, "published once, whole")
        let sent = fake.paramsForMethod("workspace.list")
        #expect(sent.count == 1)
        #expect(sent.first?["nextToken"] as? String == "t1")
        #expect(sent.first?["includeArchived"] as? Bool == true)
    }

    @Test func failedContinuationKeepsTheWholeListAndResubscribes() async throws {
        let (store, fake) = try await liveStore()
        fake.failsCancelledRequests = true
        let revisionBefore = store.workspacesRevision
        // Hold the resubscribe so the backoff window can be observed.
        let backoff = TestGate()
        store.snapshotFiller.sleep = { delay in
            if delay >= .seconds(1) { await backoff.wait() }
        }
        fake.errorMap["workspace.list"] = PageError()

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1", seq: 0, snapshot: Self.workspaces(1...100), nextToken: "t1"
        ))
        try await waitUntil("walk gave up") { store.snapshotFiller.failures == 1 }

        // A delta during the backoff must not publish the partial snapshot.
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            seq: 1,
            delta: .init(added: [], updated: [["id": "ws-5", "title": "Renamed"]], removedIds: [])
        ))
        #expect(store.snapshotFiller.isFilling)
        #expect(store.workspaces.count == 150)
        #expect(store.workspacesRevision == revisionBefore)

        backoff.open()
        try await waitUntil("resubscribed for a fresh snapshot") {
            fake.paramsForMethod("workspace.subscribe").count == 1 && fake.hasSubscriptionHandler(id: "sub-1")
        }
        #expect(fake.paramsForMethod("workspace.unsubscribe").count == 1)
        #expect(store.workspaces.count == 150)
    }

    @Test func fillThatCannotFinishKeepsThePreviousList() async throws {
        let (store, fake) = try await liveStore()
        let revisionBefore = store.workspacesRevision
        let backoff = TestGate()
        store.snapshotFiller.sleep = { delay in
            if delay >= .seconds(1) { await backoff.wait() }
        }
        fake.responseMap["workspace.list"] = ["workspaces": Self.workspaces(101...120), "nextToken": "t1"]

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1", seq: 0, snapshot: Self.workspaces(1...100), nextToken: "t1"
        ))

        try await waitUntil("walk gave up") { store.snapshotFiller.failures == 1 }
        #expect(store.workspaces.count == 150)
        #expect(store.workspacesRevision == revisionBefore)
        backoff.open()
    }

    @Test func localPatchDuringFillKeepsTheFreshSnapshotRow() async throws {
        let (store, fake) = try await liveStore()
        fake.pendingMethods = ["workspace.list"]
        // The previous list says "Workspace 5"; the fresh snapshot renamed it.
        var fresh = Self.workspaces(1...100)
        fresh[4]["title"] = "Fresh title"
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-1", seq: 0, snapshot: fresh, nextToken: "t1"))
        try await fake.waitForPendingRequests("workspace.list")

        store.updateWaiting(workspaceId: "ws-5", waiting: true)
        store.updateWaiting(workspaceId: "ws-120", waiting: true)

        fake.resolvePending("workspace.list", with: [
            "workspaces": Self.workspaces(101...150), "nextToken": NSNull()
        ] as [String: Any])
        try await waitUntil("whole snapshot published") { !store.snapshotFiller.isFilling }

        let ws5 = store.workspaces.first { $0.id == "ws-5" }
        #expect(ws5?.title == "Fresh title")
        #expect(ws5?.waiting == true)
        // Rows from unread pages come from their page, not from the old list.
        #expect(store.workspaces.first { $0.id == "ws-120" }?.waiting == false)
        #expect(store.workspaces.count == 150)
    }

    @Test func reconcilerPatchUpdatesOnlyPresentRows() {
        let reconciler = DeltaReconciler<Workspace>(
            getId: { $0["id"] as? String },
            normalize: { WorkspaceStore.parseWorkspace($0) }
        )
        reconciler.applySnapshot(seq: 0, rawItems: [["id": "ws-1", "title": "One"]])
        reconciler.patch(id: "ws-1") { row in
            var renamed = row
            renamed.title = "Patched"
            return renamed
        }
        reconciler.patch(id: "ws-2") { $0 }
        reconciler.fillFromPage([["id": "ws-1", "title": "Page"], ["id": "ws-2", "title": "Two"]])
        #expect(reconciler.values().map(\.title) == ["Patched", "Two"])
    }
}
