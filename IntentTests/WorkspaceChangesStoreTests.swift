import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceChangesStoreTests {
    func makeFake() -> FakeConnectionManager {
        let fake = FakeConnectionManager()
        fake.responseMap["events.subscribe"] = ["subscriptionId": "changes-subscription"]
        fake.responseMap["events.unsubscribe"] = [:] as [String: Any]
        fake.responseMap["gitRoot.list"] = ["gitRoots": [] as [[String: Any]]]
        fake.responseMap["file-tracking.getChanges"] = WorkspaceChangesFixture.snapshot()
        fake.responseMap["git.status"] = ["files": [] as [[String: Any]]]
        fake.responseMap["file-tracking.loadCommits"] = WorkspaceChangesFixture.page()
        return fake
    }

    func deliverChange(
        _ fake: FakeConnectionManager,
        workspaceId: String = "workspace-1",
        subscriptionId: String = "changes-subscription",
        type: String = "changes:tracked"
    ) {
        fake.deliverEvent(method: "events.event", params: [
            "subscriptionId": subscriptionId,
            "event": ["type": type, "data": ["workspaceId": workspaceId]]
        ])
    }

    @Test func refreshKeepsStagedAndUnstagedVersionsOfTheSameFile() async throws {
        let fake = makeFake()
        fake.responseMap["file-tracking.getChanges"] = WorkspaceChangesFixture.snapshot(
            [
                WorkspaceChangesFixture.change(id: "staged-row", stage: "staged"),
                WorkspaceChangesFixture.change(id: "unstaged-row"),
                WorkspaceChangesFixture.change(id: "historic-row", stage: "committed")
            ],
            truncated: true
        )
        fake.responseMap["file-tracking.loadCommits"] = WorkspaceChangesFixture.page(["first"], nextToken: "page-2")
        fake.responseMap["git.status"] = [
            "files": [
                ["path": "src/main.swift", "status": "M", "staged": true],
                ["path": "src/main.swift", "status": "M", "staged": false]
            ],
            "filesTruncated": true
        ]
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.refresh(workspaceId: "workspace-1")

        #expect(store.stagedChanges.map(\.id) == ["primary:staged:src/main.swift"])
        #expect(store.unstagedChanges.map(\.id) == ["primary:unstaged:src/main.swift"])
        #expect(store.stagedChanges.first?.path == store.unstagedChanges.first?.path)
        #expect(store.commits.map(\.hash) == ["first"])
        #expect(store.isTruncated && store.hasMoreCommits && store.hasLoaded)
        #expect(store.isLoading == false)
        #expect(store.errorMessage == nil)
        let params = try #require(fake.paramsForMethod("file-tracking.loadCommits").first)
        #expect(params["workspaceId"] as? String == "workspace-1")
        #expect(params["includeOlder"] as? Bool == false)
        #expect(params["nextToken"] == nil)
    }

    @Test func paginationUsesServerTokenAndDoesNotDuplicateCommits() async throws {
        let fake = makeFake()
        fake.responseQueueMap["file-tracking.loadCommits"] = [
            WorkspaceChangesFixture.page(["first"], nextToken: "page-2"),
            WorkspaceChangesFixture.page(["first", "second"])
        ]
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.refresh(workspaceId: "workspace-1")
        await store.loadMoreCommits()
        await store.loadMoreCommits()

        #expect(store.commits.map(\.hash) == ["first", "second"])
        #expect(store.hasMoreCommits == false)
        #expect(store.isLoadingMore == false)
        let requests = fake.paramsForMethod("file-tracking.loadCommits")
        #expect(requests.count == 2)
        let params = try #require(requests.last)
        #expect(params["nextToken"] as? String == "page-2")
        #expect(params["includeOlder"] as? Bool == false)
    }

    @Test func gitStatusReconcilesStaleTrackingAcrossStageChangesAndReverts() async throws {
        let fake = makeFake()
        fake.responseMap["file-tracking.getChanges"] = WorkspaceChangesFixture.snapshot([
            WorkspaceChangesFixture.change(path: "restaged.swift"),
            WorkspaceChangesFixture.change(path: "reverted.swift", stage: "staged")
        ], truncated: true)
        fake.responseMap["git.status"] = [
            "files": [
                ["path": "restaged.swift", "status": "M", "staged": true],
                ["path": "manual.swift", "status": "?", "staged": false]
            ]
        ]
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.startObserving(workspaceId: "workspace-1")

        #expect(store.stagedChanges.map(\.path) == ["restaged.swift"])
        #expect(store.unstagedChanges.map(\.path) == ["manual.swift"])
        #expect(store.unstagedChanges.first?.status == "untracked")
        #expect(store.stagedChanges.first?.hasLineStats == false)
        #expect(store.isTruncated == false)
        let params = try #require(fake.paramsForMethod("git.status").first)
        #expect(params["workspaceId"] as? String == "workspace-1")
        #expect(params["gitRootId"] == nil)
        #expect(params["forceRefresh"] as? Bool == true)

        fake.responseMap["git.status"] = [
            "files": [["path": "restaged.swift", "status": "M", "staged": false]]
        ]
        deliverChange(fake, type: "changes:git-status")
        try await waitUntil("unstaging updates despite unchanged attribution") {
            store.stagedChanges.isEmpty && store.unstagedChanges.map(\.path) == ["restaged.swift"]
        }
        #expect(store.unstagedChanges.first?.agentName == "Implementor")

        fake.responseMap["git.status"] = ["files": [] as [[String: Any]]]
        deliverChange(fake, type: "changes:git-status")
        try await waitUntil("revert removes tracked rows from Changes") {
            store.stagedChanges.isEmpty && store.unstagedChanges.isEmpty
        }
        store.stopObserving()
    }

    @Test func gitStatusFailureKeepsLastSnapshotAndReportsError() async {
        let fake = makeFake()
        fake.responseMap["git.status"] = ["files": [["path": "manual.swift", "status": "?", "staged": false]]]
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.refresh(workspaceId: "workspace-1")
        fake.errorMap["git.status"] = URLError(.timedOut)
        await store.refresh(workspaceId: "workspace-1")
        #expect(store.unstagedChanges.map(\.path) == ["manual.swift"])
        #expect(store.errorMessage != nil)
        #expect(store.isLoading == false)
        fake.errorMap.removeValue(forKey: "git.status")
        fake.responseMap["git.status"] = ["files": [] as [[String: Any]]]
        await store.refresh(workspaceId: "workspace-1")
        #expect(store.unstagedChanges.isEmpty)
        #expect(store.errorMessage == nil)
    }

    @Test func changedBoundaryRestartsHistoryWithoutAppendingAnotherRange() async {
        let fake = makeFake()
        fake.responseQueueMap["file-tracking.loadCommits"] = [
            WorkspaceChangesFixture.page(["old"], nextToken: "page-2"),
            WorkspaceChangesFixture.page(["wrong-range"], boundary: "rebased"),
            WorkspaceChangesFixture.page(["new"], boundary: "rebased")
        ]
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.refresh(workspaceId: "workspace-1")
        await store.loadMoreCommits()
        #expect(store.commits.map(\.hash) == ["new"])
        #expect(store.isLoadingMore == false)
        #expect(fake.paramsForMethod("file-tracking.getChanges").count == 2)
    }

    @Test func errorsKeepPreviousSnapshotAndRetryClearsError() async {
        let fake = makeFake()
        fake.responseMap["file-tracking.getChanges"] = WorkspaceChangesFixture.snapshot([WorkspaceChangesFixture.change()])
        fake.responseMap["git.status"] = ["files": [["path": "src/main.swift", "status": "M", "staged": false]]]
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.refresh(workspaceId: "workspace-1")
        fake.responseMap["file-tracking.getChanges"] = ["invalid": true]
        await store.refresh(workspaceId: "workspace-1")

        #expect(store.unstagedChanges.count == 1)
        #expect(store.hasLoaded)
        #expect(store.errorMessage != nil)
        #expect(store.isLoading == false)
        fake.responseMap["file-tracking.getChanges"] = WorkspaceChangesFixture.snapshot()
        fake.responseMap["git.status"] = ["files": [] as [[String: Any]]]
        await store.refresh(workspaceId: "workspace-1")
        #expect(store.unstagedChanges.isEmpty)
        #expect(store.errorMessage == nil)
    }

    @Test func failedCommitPageCanBeRetriedWithTheSameToken() async {
        let fake = makeFake()
        fake.responseMap["file-tracking.loadCommits"] = WorkspaceChangesFixture.page(["first"], nextToken: "page-2")
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.refresh(workspaceId: "workspace-1")
        fake.errorMap["file-tracking.loadCommits"] = URLError(.notConnectedToInternet)
        await store.loadMoreCommits()
        #expect(store.commits.map(\.hash) == ["first"])
        #expect(store.hasMoreCommits)
        #expect(store.errorMessage != nil)
        fake.errorMap.removeValue(forKey: "file-tracking.loadCommits")
        fake.responseMap["file-tracking.loadCommits"] = WorkspaceChangesFixture.page(["second"])
        await store.loadMoreCommits()
        #expect(store.commits.map(\.hash) == ["first", "second"])
        #expect(store.errorMessage == nil)
    }

    @Test func observingSubscribesBeforeSeedingAndReconnectRefreshes() async throws {
        let fake = makeFake()
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.startObserving(workspaceId: "workspace-1")
        #expect(fake.requestLog.first?.method == "events.subscribe")
        let params = try #require(fake.paramsForMethod("events.subscribe").first)
        #expect(params["workspaceId"] as? String == "workspace-1")
        #expect(params["eventTypes"] as? [String] == ["changes:tracked", "changes:git-status", "git:*", "gitRoot:*"])
        #expect(fake.eventHandlerCount == 1)
        fake.responseMap["file-tracking.loadCommits"] = WorkspaceChangesFixture.page(["after-reconnect"])
        fake.simulateDisconnect()
        fake.simulateConnect()
        try await waitUntil("Changes history refresh after reconnect") {
            store.commits.first?.hash == "after-reconnect"
        }
        #expect(fake.paramsForMethod("events.subscribe").count == 2)
        store.stopObserving()
        #expect(fake.eventHandlerCount == 0)
        try await fake.waitForRequests("events.unsubscribe")
    }

    @Test func onlyMatchingWorkspaceAndSubscriptionEventsRefresh() async throws {
        let fake = makeFake()
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.startObserving(workspaceId: "workspace-1")
        fake.clearRequestLog()
        deliverChange(fake, workspaceId: "another-workspace")
        deliverChange(fake, subscriptionId: "foreign-subscription")
        deliverChange(fake, type: "changes:metrics-changed")
        try await expectNever("refresh for foreign or unrelated Changes events") {
            fake.didCallMethod("file-tracking.getChanges")
        }
        fake.responseMap["file-tracking.loadCommits"] = WorkspaceChangesFixture.page(["new-commit"])
        deliverChange(fake, type: "git:commit")
        try await waitUntil("Changes refresh for git:commit") { store.commits.first?.hash == "new-commit" }
        store.stopObserving()
    }

    @Test func storeDeallocationReleasesLocalAndRemoteObservation() async throws {
        let fake = makeFake()
        var store: WorkspaceChangesStore? = WorkspaceChangesStore(connectionManager: fake)
        await store?.startObserving(workspaceId: "workspace-1")
        weak var weakStore = store
        store = nil
        #expect(weakStore == nil)
        #expect(fake.eventHandlerCount == 0)
        try await fake.waitForRequests("events.unsubscribe")
    }
}
