import Foundation
@testable import Intent
import Testing

extension WorkspaceChangesFixture {
    static func root(_ id: String = "root-a") -> [String: Any] {
        [
            "id": id,
            "path": "/workspace/packages/\(id)",
            "repoName": "Repository \(id)",
            "branch": "feature/changes",
            "registeredCommitSha": "base-\(id)"
        ]
    }

    static func secondaryPage(_ hashes: [String], nextToken: String? = nil) -> [String: Any] {
        let summaries = hashes.map { hash in
            var summary = commit(hash)
            summary.removeValue(forKey: "isPushed")
            return summary
        }
        return ["items": summaries, "nextToken": nextToken as Any? ?? NSNull()]
    }

    static func secondaryStatus() -> [String: Any] {
        [
            "files": [
                ["path": "same.swift", "status": "M", "staged": true],
                ["path": "same.swift", "status": "M", "staged": false],
                ["path": "new.swift", "status": "?", "staged": false]
            ],
            "filesTruncated": true
        ]
    }
}

extension WorkspaceChangesModelTests {
    @Test func repositoryInventoryUsesRepoNameAndFallsBackToPath() throws {
        var fallback = WorkspaceChangesFixture.root("root-b")
        fallback.removeValue(forKey: "repoName")
        fallback.removeValue(forKey: "branch")
        fallback.removeValue(forKey: "registeredCommitSha")
        let roots = try WorkspaceGitRoot.parseList(["gitRoots": [WorkspaceChangesFixture.root(), fallback]])
        #expect(roots[0].displayName == "Repository root-a")
        #expect(roots[0].branch == "feature/changes")
        #expect(roots[0].registeredCommitSha == "base-root-a")
        #expect(roots[1].displayName == "root-b")
        #expect(roots[1].branch == nil)
        #expect(roots[1].registeredCommitSha == nil)
        #expect(throws: WorkspaceChangesDecodingError.self) {
            try WorkspaceGitRoot.parseList(["gitRoots": [["id": "incomplete"]]])
        }
    }

    @Test func secondaryStatusPreservesMixedStagesWithoutInventingStats() throws {
        let snapshot = try WorkspaceChangesSnapshot(WorkspaceChangesFixture.secondaryStatus(), rootId: "root-a")
        #expect(snapshot.changes.map(\.stage) == ["staged", "unstaged", "unstaged"])
        #expect(snapshot.changes.map(\.status) == ["modified", "modified", "untracked"])
        #expect(snapshot.changes[0].id != snapshot.changes[1].id)
        #expect(snapshot.changes.allSatisfy { !$0.hasLineStats })
        #expect(snapshot.isTruncated)
        let other = try WorkspaceChangesSnapshot(WorkspaceChangesFixture.secondaryStatus(), rootId: "root-b")
        #expect(snapshot.changes[0].id != other.changes[0].id)
    }

    @Test func secondaryCommitsExcludeRegistrationBoundaryAndOlderHistory() throws {
        let root = try #require(WorkspaceGitRoot.parse(WorkspaceChangesFixture.root()))
        let page = try WorkspaceCommitPage(
            WorkspaceChangesFixture.secondaryPage(["workspace-commit", "base-root-a", "older"], nextToken: "more"),
            root: root
        )
        #expect(page.commits.map(\.hash) == ["workspace-commit"])
        #expect(page.commits.first?.isPushedKnown == false)
        #expect(page.nextToken == nil)
        #expect(page.boundarySha == "base-root-a")
        #expect(WorkspaceCommit.parse(WorkspaceChangesFixture.commit())?.isPushedKnown == true)
        #expect(WorkspaceChange.parse(WorkspaceChangesFixture.change())?.hasLineStats == true)
    }
}

extension WorkspaceChangesStoreTests {
    @Test func returningFromCommitRestoresRepositoryButChangingWorkspaceResetsIt() async {
        let fake = makeRootsFake()
        fake.responseMap["git.commits"] = WorkspaceChangesFixture.secondaryPage(["new"])
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.startObserving(workspaceId: "workspace-1")
        await store.selectRoot(id: "root-a")
        store.stopObserving(preservingSnapshot: true)
        #expect(store.selectedRootId == "root-a")
        #expect(store.commits.map(\.hash) == ["new"])

        fake.clearRequestLog()
        await store.startObserving(workspaceId: "workspace-1")
        #expect(store.selectedRootId == "root-a")
        #expect(fake.paramsForMethod("git.commits").last?["gitRootId"] as? String == "root-a")
        store.stopObserving(preservingSnapshot: true)
        await store.startObserving(workspaceId: "workspace-2")
        #expect(store.selectedRootId == nil)
        #expect(fake.paramsForMethod("git.status").last?["workspaceId"] as? String == "workspace-2")
        #expect(fake.paramsForMethod("git.status").last?["gitRootId"] == nil)
        store.stopObserving()
    }

    func makeRootsFake() -> FakeConnectionManager {
        let fake = makeFake()
        fake.responseMap["gitRoot.list"] = [
            "gitRoots": [WorkspaceChangesFixture.root(), WorkspaceChangesFixture.root("root-b")]
        ]
        fake.responseMap["git.status"] = WorkspaceChangesFixture.secondaryStatus()
        fake.responseMap["git.commits"] = WorkspaceChangesFixture.secondaryPage([])
        return fake
    }

    func deliverRootEvent(_ fake: FakeConnectionManager, type: String = "git:commit", rootId: String = "root-a") {
        fake.deliverEvent(method: "events.event", params: [
            "subscriptionId": "changes-subscription",
            "event": ["type": type, "data": ["workspaceId": "workspace-1", "gitRootId": rootId]]
        ])
    }

    @Test func selectingSecondaryRepositoryScopesEveryGitRead() async throws {
        let fake = makeRootsFake()
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.refresh(workspaceId: "workspace-1")
        fake.clearRequestLog()
        fake.responseMap["git.commits"] = WorkspaceChangesFixture.secondaryPage(["new", "base-root-a", "older"])
        await store.selectRoot(id: "root-a")

        #expect(store.selectedRootId == "root-a")
        #expect(store.selectedRoot?.displayName == "Repository root-a")
        #expect(store.stagedChanges.map(\.path) == ["same.swift"])
        #expect(store.unstagedChanges.map(\.path) == ["same.swift", "new.swift"])
        #expect(store.commits.map(\.hash) == ["new"])
        #expect(store.isTruncated)
        #expect(store.repositoryErrorMessage == nil)
        for method in ["git.status", "git.commits"] {
            let params = try #require(fake.paramsForMethod(method).first)
            #expect(params["gitRootId"] as? String == "root-a")
            #expect(params["workspaceId"] as? String == "workspace-1")
        }
        #expect(fake.paramsForMethod("git.status").first?["forceRefresh"] as? Bool == true)
        #expect(fake.didCallMethod("file-tracking.getChanges") == false)
        #expect(fake.didCallMethod("file-tracking.loadCommits") == false)
        #expect(fake.didCallMethod("git.diffs") == false)
    }

    @Test func secondaryPaginationContinuesUntilTheBoundary() async throws {
        let fake = makeRootsFake()
        fake.responseQueueMap["git.commits"] = [
            WorkspaceChangesFixture.secondaryPage(["new"], nextToken: "page-2"),
            WorkspaceChangesFixture.secondaryPage(["new", "next", "base-root-a", "older"], nextToken: "page-3")
        ]
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.refresh(workspaceId: "workspace-1")
        await store.selectRoot(id: "root-a")
        #expect(store.hasMoreCommits)
        await store.loadMoreCommits()
        await store.loadMoreCommits()
        #expect(store.commits.map(\.hash) == ["new", "next"])
        #expect(store.hasMoreCommits == false)
        let params = try #require(fake.paramsForMethod("git.commits").last)
        #expect(params["gitRootId"] as? String == "root-a")
        #expect(params["nextToken"] as? String == "page-2")
        #expect(fake.paramsForMethod("git.commits").count == 2)
    }

    @Test func repositoryInventoryFailureDoesNotPreventPrimaryReads() async {
        let fake = makeFake()
        fake.errorMap["gitRoot.list"] = URLError(.timedOut)
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.refresh(workspaceId: "workspace-1")
        #expect(store.repositoryErrorMessage != nil)
        #expect(store.hasLoaded)
        #expect(store.errorMessage == nil)
        #expect(fake.didCallMethod("file-tracking.getChanges"))
        fake.errorMap.removeValue(forKey: "gitRoot.list")
        await store.refresh(workspaceId: "workspace-1")
        #expect(store.repositoryErrorMessage == nil)
    }

    @Test func secondaryReadFailureIsVisibleWithoutSilentlyShowingMain() async {
        let fake = makeRootsFake()
        fake.errorMap["git.status"] = URLError(.cannotFindHost)
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.refresh(workspaceId: "workspace-1")
        fake.clearRequestLog()
        await store.selectRoot(id: "root-a")
        #expect(store.selectedRootId == "root-a")
        #expect(store.errorMessage != nil)
        #expect(store.hasLoaded == false)
        #expect(store.stagedChanges.isEmpty && store.unstagedChanges.isEmpty)
        #expect(fake.didCallMethod("file-tracking.getChanges") == false)
    }

    @Test func reconnectPreservesSelectionAndWorkspaceSwitchResetsIt() async throws {
        let fake = makeRootsFake()
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.startObserving(workspaceId: "workspace-1")
        await store.selectRoot(id: "root-a")
        fake.clearRequestLog()
        fake.simulateDisconnect()
        fake.simulateConnect()
        try await fake.waitForRequests("git.commits")
        #expect(store.selectedRootId == "root-a")
        #expect(fake.paramsForMethod("git.status").first?["gitRootId"] as? String == "root-a")
        #expect(fake.didCallMethod("file-tracking.getChanges") == false)
        await store.startObserving(workspaceId: "workspace-2")
        #expect(store.selectedRootId == nil)
        #expect(store.selectedRoot == nil)
        #expect(fake.paramsForMethod("file-tracking.getChanges").last?["workspaceId"] as? String == "workspace-2")
        store.stopObserving()
    }
}
