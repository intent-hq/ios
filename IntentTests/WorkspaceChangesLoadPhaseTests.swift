import Foundation
@testable import Intent
import Testing

/// The Changes snapshot is one `LoadPhase`; a Load More failure is kept apart in `pageFailure`.
@MainActor
struct WorkspaceChangesLoadPhaseTests {
    private static let offline = NSError(
        domain: "WebSocket", code: -1, userInfo: [NSLocalizedDescriptionKey: "Request timed out"]
    )

    private func makeFake() -> FakeConnectionManager {
        let fake = FakeConnectionManager()
        fake.responseMap["gitRoot.list"] = ["gitRoots": [] as [[String: Any]]]
        fake.responseMap["file-tracking.getChanges"] = WorkspaceChangesFixture.snapshot([WorkspaceChangesFixture.change()])
        // Git status confirms the tracked row; an empty status would drop it as stale.
        fake.responseMap["git.status"] = ["files": [["path": "src/main.swift", "status": "M", "staged": false]]]
        fake.responseMap["file-tracking.loadCommits"] = WorkspaceChangesFixture.page(["first"], nextToken: "page-2")
        return fake
    }

    @Test func movesFromLoadingToLoaded() async throws {
        let fake = makeFake()
        fake.pendingMethods = ["file-tracking.getChanges"]
        let store = WorkspaceChangesStore(connectionManager: fake)
        let refresh = Task { await store.refresh(workspaceId: "workspace-1") }
        try await fake.waitForPendingRequests("file-tracking.getChanges")
        #expect(store.loadPhase == .loading(lastLoadedAt: nil))

        fake.resolvePending("file-tracking.getChanges", with: WorkspaceChangesFixture.snapshot([WorkspaceChangesFixture.change()]))
        await refresh.value
        #expect(store.loadPhase.hasLoaded && !store.isLoading)
        #expect(store.unstagedChanges.count == 1)
    }

    @Test func anEmptySnapshotIsLoadedNotFailed() async {
        let fake = makeFake()
        fake.responseMap["file-tracking.getChanges"] = WorkspaceChangesFixture.snapshot()
        fake.responseMap["git.status"] = ["files": [] as [[String: Any]]]
        fake.responseMap["file-tracking.loadCommits"] = WorkspaceChangesFixture.page()
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.refresh(workspaceId: "workspace-1")
        #expect(store.loadPhase.hasLoaded && store.errorMessage == nil)
        #expect(store.unstagedChanges.isEmpty && store.stagedChanges.isEmpty && store.commits.isEmpty)
    }

    @Test func aFailedFirstLoadIsFailedNotLoading() async {
        let fake = makeFake()
        fake.errorMap["file-tracking.getChanges"] = Self.offline
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.refresh(workspaceId: "workspace-1")
        #expect(store.loadPhase == .failed("Request timed out"))
        #expect(!store.isLoading && !store.hasLoaded)
    }

    @Test func aFailedRefreshKeepsRowsAndTheMessageUntilRetryStarts() async throws {
        let fake = makeFake()
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.refresh(workspaceId: "workspace-1")
        let loadedAt = try #require(store.loadPhase.lastLoadedAt)
        fake.errorMap["file-tracking.getChanges"] = Self.offline

        await store.refresh(workspaceId: "workspace-1")
        #expect(store.loadPhase == .refreshFailed("Request timed out", lastLoadedAt: loadedAt))
        #expect(store.unstagedChanges.count == 1 && store.errorMessage == "Request timed out")

        fake.errorMap.removeValue(forKey: "file-tracking.getChanges")
        fake.pendingMethods = ["file-tracking.getChanges"]
        let retry = Task { await store.refresh(workspaceId: "workspace-1") }
        try await fake.waitForPendingRequests("file-tracking.getChanges")
        #expect(store.loadPhase == .loading(lastLoadedAt: loadedAt), "Retry shows loading, not the old error")
        #expect(store.errorMessage == nil && store.unstagedChanges.count == 1)
        fake.responseMap["git.status"] = ["files": [] as [[String: Any]]]
        fake.resolvePending("file-tracking.getChanges", with: WorkspaceChangesFixture.snapshot())
        await retry.value
        #expect(store.loadPhase.hasLoaded && store.errorMessage == nil && store.unstagedChanges.isEmpty)
    }

    @Test func aFailedPageIsAPageFailureThatARefreshClears() async {
        let fake = makeFake()
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.refresh(workspaceId: "workspace-1")
        fake.errorMap["file-tracking.loadCommits"] = Self.offline

        await store.loadMoreCommits()
        #expect(store.pageFailure == "Request timed out")
        #expect(store.loadPhase.hasLoaded && store.loadPhase.anyFailureMessage == nil)
        #expect(store.errorMessage == "Request timed out")

        fake.errorMap.removeValue(forKey: "file-tracking.loadCommits")
        await store.refresh(workspaceId: "workspace-1")
        #expect(store.pageFailure == nil && store.errorMessage == nil)
    }

    @Test func stoppingReturnsToIdle() async {
        let fake = makeFake()
        fake.errorMap["file-tracking.getChanges"] = Self.offline
        let store = WorkspaceChangesStore(connectionManager: fake)
        await store.refresh(workspaceId: "workspace-1")
        store.stopObserving()
        #expect(store.loadPhase == .idle && store.errorMessage == nil)
    }
}
