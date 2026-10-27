import Foundation
@testable import Intent
import Testing

extension WorkspaceChangesStoreTests {
    @Test func selectingRootClearsRowsAndPaginationBeforeInventoryReadReturns() async throws {
        let fake = makeRootsFake()
        fake.responseMap["file-tracking.getChanges"] = WorkspaceChangesFixture.snapshot([WorkspaceChangesFixture.change()])
        fake.responseMap["file-tracking.loadCommits"] = WorkspaceChangesFixture.page(["main"], nextToken: "more")
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.refresh(workspaceId: "workspace-1")
        fake.pendingMethods.insert("gitRoot.list")
        let selection = Task { await store.selectRoot(id: "root-a") }
        try await fake.waitForPendingRequests("gitRoot.list")
        #expect(store.selectedRootId == "root-a")
        #expect(store.stagedChanges.isEmpty && store.unstagedChanges.isEmpty && store.commits.isEmpty)
        #expect(store.hasMoreCommits == false)
        #expect(store.hasLoaded == false)
        fake.resolvePending("gitRoot.list", with: ["gitRoots": [WorkspaceChangesFixture.root()]])
        await selection.value
        #expect(store.hasLoaded)
    }

    @Test func staleStatusForSamePathCannotOverwriteAnotherRoot() async throws {
        let fake = makeRootsFake()
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.refresh(workspaceId: "workspace-1")
        fake.pendingMethods.insert("git.status")
        let first = Task { await store.selectRoot(id: "root-a") }
        try await fake.waitForPendingRequests("git.status")
        fake.pendingMethods.remove("git.status")
        fake.responseMap["git.commits"] = WorkspaceChangesFixture.secondaryPage(["root-b-commit"])
        await store.selectRoot(id: "root-b")
        fake.resolvePending("git.status", with: [
            "files": [["path": "same.swift", "status": "D", "staged": true]]
        ])
        await first.value
        #expect(store.selectedRootId == "root-b")
        #expect(store.stagedChanges.first?.id == "root-b:staged:same.swift")
        #expect(store.stagedChanges.first?.status == "modified")
        #expect(store.commits.map(\.hash) == ["root-b-commit"])
        #expect(fake.paramsForMethod("git.commits").count == 1)
    }

    @Test func staleSecondaryPageCannotAppendAfterReturningToMain() async throws {
        let fake = makeRootsFake()
        fake.responseMap["git.commits"] = WorkspaceChangesFixture.secondaryPage(["secondary"], nextToken: "more")
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.refresh(workspaceId: "workspace-1")
        await store.selectRoot(id: "root-a")
        fake.pendingMethods.insert("git.commits")
        let page = Task { await store.loadMoreCommits() }
        try await fake.waitForPendingRequests("git.commits")
        fake.responseMap["file-tracking.loadCommits"] = WorkspaceChangesFixture.page(["main-only"])
        await store.selectRoot(id: nil)
        fake.resolvePending("git.commits", with: WorkspaceChangesFixture.secondaryPage(["stale-secondary"]))
        await page.value
        #expect(store.selectedRootId == nil)
        #expect(store.commits.map(\.hash) == ["main-only"])
        #expect(store.hasMoreCommits == false)
        #expect(store.isLoadingMore == false)
    }

    @Test func staleInventoryCannotRemoveNewSelection() async throws {
        let fake = makeRootsFake()
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.refresh(workspaceId: "workspace-1")
        fake.pendingMethods.insert("gitRoot.list")
        let oldInventory = Task { await store.refresh(workspaceId: "workspace-1") }
        try await fake.waitForPendingRequests("gitRoot.list")
        fake.pendingMethods.remove("gitRoot.list")
        fake.responseMap["gitRoot.list"] = ["gitRoots": [WorkspaceChangesFixture.root("root-b")]]
        await store.selectRoot(id: "root-b")
        fake.resolvePending("gitRoot.list", with: ["gitRoots": [WorkspaceChangesFixture.root()]])
        await oldInventory.value
        #expect(store.roots.map(\.id) == ["root-b"])
        #expect(store.selectedRootId == "root-b")
        #expect(store.repositoryErrorMessage == nil)
    }

    @Test func removedSelectedRootClearsRowsAndFallsBackToMain() async throws {
        let fake = makeRootsFake()
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.startObserving(workspaceId: "workspace-1")
        await store.selectRoot(id: "root-a")
        fake.responseMap["gitRoot.list"] = ["gitRoots": [WorkspaceChangesFixture.root("root-b")]]
        fake.pendingMethods.insert("file-tracking.getChanges")
        deliverRootEvent(fake, type: "gitRoot:unregistered")
        try await fake.waitForPendingRequests("file-tracking.getChanges")
        #expect(store.selectedRootId == nil)
        #expect(store.stagedChanges.isEmpty && store.unstagedChanges.isEmpty)
        fake.responseMap["git.status"] = ["files": [["path": "main.swift", "status": "M", "staged": false]]]
        fake.resolvePending("file-tracking.getChanges", with: WorkspaceChangesFixture.snapshot([
            WorkspaceChangesFixture.change(id: "main-after-removal")
        ]))
        try await waitUntil("primary repository refresh after removing the selected root") {
            store.unstagedChanges.first?.path == "main.swift" && !store.isLoading
        }
        store.stopObserving()
    }

    @Test(arguments: ["changes:tracked", "changes:git-status", "git:commit"])
    func workspaceWideEventsRefreshSelectedRoot(type: String) async throws {
        let fake = makeRootsFake()
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.startObserving(workspaceId: "workspace-1")
        await store.selectRoot(id: "root-a")
        fake.clearRequestLog()
        fake.responseMap["git.status"] = [
            "files": [["path": "edited.swift", "status": "M", "staged": false]]
        ]
        fake.responseMap["git.commits"] = WorkspaceChangesFixture.secondaryPage(["workspace-event"])

        deliverChange(fake, type: type)

        try await waitUntil("selected repository refresh from a workspace-wide event") {
            store.unstagedChanges.map(\.path) == ["edited.swift"]
                && store.commits.first?.hash == "workspace-event" && !store.isLoading
        }
        #expect(store.selectedRootId == "root-a")
        #expect(store.stagedChanges.isEmpty)
        for method in ["git.status", "git.commits"] {
            let params = try #require(fake.paramsForMethod(method).first)
            #expect(params["gitRootId"] as? String == "root-a")
            #expect(params["workspaceId"] as? String == "workspace-1")
        }
        #expect(fake.didCallMethod("file-tracking.getChanges") == false)
        #expect(fake.didCallMethod("file-tracking.loadCommits") == false)
        store.stopObserving()
    }

    @Test func selectedRootEventsRefreshWhileOtherRootsAreIgnored() async throws {
        let fake = makeRootsFake()
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.startObserving(workspaceId: "workspace-1")
        await store.selectRoot(id: "root-a")
        fake.clearRequestLog()
        deliverRootEvent(fake, rootId: "root-b")
        try await expectNever("refresh from another repository's changes") {
            fake.didCallMethod("git.status") || fake.didCallMethod("gitRoot.list")
        }
        fake.responseMap["git.commits"] = WorkspaceChangesFixture.secondaryPage(["selected-event"])
        deliverRootEvent(fake)
        try await waitUntil("refresh for selected repository event") {
            store.commits.first?.hash == "selected-event"
        }
        #expect(fake.paramsForMethod("git.status").first?["gitRootId"] as? String == "root-a")
        store.stopObserving()
    }
}
