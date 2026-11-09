import Foundation
@testable import Intent
import Testing

/// Event-driven refreshes: one in flight, one trailing refresh per burst, and
/// nothing stale after teardown or a workspace switch.
extension WorkspaceChangesStoreTests {
    func commitReads(_ fake: FakeConnectionManager, workspaceId: String = "workspace-1") -> Int {
        fake.paramsForMethod("file-tracking.loadCommits").filter { $0["workspaceId"] as? String == workspaceId }.count
    }

    @Test func eventsDuringARefreshCollapseIntoOneTrailingRefresh() async throws {
        let fake = makeFake()
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.startObserving(workspaceId: "workspace-1")
        fake.clearRequestLog()
        fake.pendingMethods = ["file-tracking.loadCommits"]
        deliverChange(fake)
        try await fake.waitForPendingRequests("file-tracking.loadCommits")
        deliverChange(fake)
        deliverChange(fake, type: "git:commit")
        deliverChange(fake)
        try await expectNever("a second refresh while the first is in flight") { commitReads(fake) > 1 }
        fake.resolvePending("file-tracking.loadCommits", with: WorkspaceChangesFixture.page(["stale"]))
        try await fake.waitForPendingRequests("file-tracking.loadCommits")
        #expect(store.commits.isEmpty, "an invalidated refresh must not apply")
        fake.resolvePending("file-tracking.loadCommits", with: WorkspaceChangesFixture.page(["fresh"]))
        try await waitUntil("trailing refresh applied") { store.commits.map(\.hash) == ["fresh"] }
        try await expectNever("a third refresh after the burst settled") { commitReads(fake) > 2 }
        store.stopObserving()
    }

    @Test func eventDuringTheTrailingRefreshEarnsAnother() async throws {
        let fake = makeFake()
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.startObserving(workspaceId: "workspace-1")
        fake.clearRequestLog()
        fake.pendingMethods = ["file-tracking.loadCommits"]
        deliverChange(fake)
        try await fake.waitForPendingRequests("file-tracking.loadCommits")
        deliverChange(fake)
        try await expectNever("a second refresh while the first is in flight") { commitReads(fake) > 1 }
        fake.resolvePending("file-tracking.loadCommits", with: WorkspaceChangesFixture.page(["stale-1"]))
        try await fake.waitForPendingRequests("file-tracking.loadCommits")
        deliverChange(fake)
        try await expectNever("a third refresh while the second is in flight") { commitReads(fake) > 2 }
        fake.resolvePending("file-tracking.loadCommits", with: WorkspaceChangesFixture.page(["stale-2"]))
        try await fake.waitForPendingRequests("file-tracking.loadCommits")
        #expect(store.commits.isEmpty)
        fake.resolvePending("file-tracking.loadCommits", with: WorkspaceChangesFixture.page(["fresh"]))
        try await waitUntil("final refresh applied") { store.commits.map(\.hash) == ["fresh"] }
        try await expectNever("a fourth refresh after events settled") { commitReads(fake) > 3 }
        store.stopObserving()
    }

    @Test func stopObservingDropsTheInFlightAndTrailingEventRefresh() async throws {
        let fake = makeFake()
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.startObserving(workspaceId: "workspace-1")
        fake.clearRequestLog()
        fake.pendingMethods = ["file-tracking.loadCommits"]
        deliverChange(fake)
        try await fake.waitForPendingRequests("file-tracking.loadCommits")
        deliverChange(fake)
        try await expectNever("a second refresh while the first is in flight") { commitReads(fake) > 1 }
        store.stopObserving(preservingSnapshot: true)
        fake.resolvePending("file-tracking.loadCommits", with: WorkspaceChangesFixture.page(["stale"]))
        try await expectNever("a stale or trailing refresh after teardown") {
            commitReads(fake) > 1 || !store.commits.isEmpty
        }
    }

    @Test func workspaceSwitchDropsTheOldWorkspaceEventRefresh() async throws {
        let fake = makeFake()
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.startObserving(workspaceId: "workspace-1")
        fake.clearRequestLog()
        fake.pendingMethods = ["file-tracking.loadCommits"]
        deliverChange(fake)
        try await fake.waitForPendingRequests("file-tracking.loadCommits")
        deliverChange(fake)
        try await expectNever("a second refresh while the first is in flight") { commitReads(fake) > 1 }
        fake.pendingMethods = []
        fake.responseMap["file-tracking.loadCommits"] = WorkspaceChangesFixture.page(["workspace-2"])
        await store.startObserving(workspaceId: "workspace-2")
        #expect(store.commits.map(\.hash) == ["workspace-2"])
        fake.resolvePending("file-tracking.loadCommits", with: WorkspaceChangesFixture.page(["stale"]))
        try await expectNever("a stale or trailing workspace-1 refresh after the switch") {
            commitReads(fake) > 1 || store.commits.map(\.hash) != ["workspace-2"]
        }
        store.stopObserving()
    }
}
