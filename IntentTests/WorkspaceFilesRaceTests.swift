import Foundation
@testable import Intent
import Testing

extension WorkspaceFilesStoreTests {
    @Test func workspaceSwitchClearsRowsAndOldFailuresCannotClearCurrentLoading() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["file.list"] = [entry("src", directory: true)]
        let store = WorkspaceFilesStore(connection: fake)
        await store.start(workspaceId: "old")
        fake.pendingMethods.insert("file.list")
        let old = Task { await store.toggleDirectory(path: "src") }
        try await fake.waitForPendingRequests("file.list")
        #expect(store.loadingPaths == ["src"])
        let current = Task { await store.start(workspaceId: "new") }
        try await fake.waitForPendingRequests("file.list", count: 2)
        #expect(store.workspaceId == "new")
        #expect(store.rows.isEmpty && store.expandedPaths.isEmpty)
        #expect(store.hasLoaded == false)
        #expect(store.loadingPaths == ["."])
        fake.failPending("file.list", with: URLError(.timedOut))
        await old.value
        #expect(store.errorsByPath.isEmpty)
        #expect(store.loadingPaths == ["."])
        fake.resolvePending("file.list", with: [["name": "Current.swift", "type": "file"]])
        await current.value
        #expect(store.rows.map(\.path) == ["Current.swift"])
        #expect(store.loadingPaths.isEmpty)
    }

    @Test func laterRefreshWinsOverAnEarlierReplyForTheSameWorkspace() async throws {
        let fake = FakeConnectionManager()
        fake.pendingMethods.insert("file.list")
        let store = WorkspaceFilesStore(connection: fake)
        let old = Task { await store.start(workspaceId: "workspace") }
        try await fake.waitForPendingRequests("file.list")
        fake.pendingMethods.remove("file.list")
        fake.responseMap["file.list"] = [entry("Current.swift")]
        await store.refresh()
        fake.resolvePending("file.list", with: [["name": "Stale.swift", "type": "file"]])
        await old.value
        #expect(store.rows.map(\.path) == ["Current.swift"])
        #expect(store.hasLoaded && store.loadingPaths.isEmpty && store.errorsByPath.isEmpty)
    }

    @Test func resetRejectsLateRepliesEvenAfterRestartingTheSameWorkspace() async throws {
        let fake = FakeConnectionManager()
        fake.pendingMethods.insert("file.list")
        let store = WorkspaceFilesStore(connection: fake)
        let old = Task { await store.start(workspaceId: "workspace") }
        try await fake.waitForPendingRequests("file.list")
        store.reset()
        #expect(store.workspaceId == nil && store.hasLoaded == false)
        #expect(store.loadingPaths.isEmpty && store.entriesByPath.isEmpty)
        fake.pendingMethods.remove("file.list")
        fake.responseMap["file.list"] = [] as [[String: Any]]
        await store.start(workspaceId: "workspace")
        fake.resolvePending("file.list", with: [["name": "Stale.swift", "type": "file"]])
        await old.value
        #expect(store.hasLoaded && store.rows.isEmpty && store.errorsByPath.isEmpty)
    }

    @Test func removedSubfolderCannotReturnFromAnOutstandingReply() async throws {
        let fake = FakeConnectionManager()
        fake.responseQueueMap["file.list"] = [
            [entry("src", directory: true)],
            [entry("nested", directory: true)]
        ]
        let store = WorkspaceFilesStore(connection: fake)
        await store.start(workspaceId: "workspace")
        await store.toggleDirectory(path: "src")
        fake.pendingMethods.insert("file.list")
        let old = Task { await store.toggleDirectory(path: "src/nested") }
        try await fake.waitForPendingRequests("file.list")
        fake.pendingMethods.remove("file.list")
        fake.responseMap["file.list"] = [] as [[String: Any]]
        await store.retry(path: "src")
        #expect(store.expandedPaths == ["src"])
        #expect(store.loadingPaths.isEmpty)
        fake.resolvePending("file.list", with: [["name": "Stale.swift", "type": "file"]])
        await old.value
        #expect(store.entriesByPath["src/nested"] == nil)
        #expect(store.rows.map(\.path) == ["src"])
    }

    @Test func collapsingDuringLoadKeepsReplyCachedWithoutReopeningFolder() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["file.list"] = [entry("src", directory: true)]
        let store = WorkspaceFilesStore(connection: fake)
        await store.start(workspaceId: "workspace")
        fake.pendingMethods.insert("file.list")
        let opening = Task { await store.toggleDirectory(path: "src") }
        try await fake.waitForPendingRequests("file.list")
        await store.toggleDirectory(path: "src")
        fake.resolvePending("file.list", with: [["name": "Cached.swift", "type": "file"]])
        await opening.value
        #expect(store.expandedPaths.isEmpty)
        #expect(store.rows.map(\.path) == ["src"])
        #expect(store.entriesByPath["src"]?.first?.name == "Cached.swift")
        fake.clearRequestLog()
        await store.toggleDirectory(path: "src")
        #expect(store.rows.map(\.path) == ["src", "src/Cached.swift"])
        #expect(paths(fake).isEmpty)
    }

    @Test func cancelledFolderRequestCanLoadOnReentryWithoutAnError() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["file.list"] = [entry("src", directory: true)]
        let store = WorkspaceFilesStore(connection: fake)
        await store.start(workspaceId: "workspace")
        fake.pendingMethods.insert("file.list")
        let opening = Task { await store.toggleDirectory(path: "src") }
        try await fake.waitForPendingRequests("file.list")
        opening.cancel()
        await opening.value
        #expect(store.loadingPaths.isEmpty && store.errorsByPath.isEmpty)
        #expect(store.expandedPaths == ["src"])
        fake.pendingMethods.remove("file.list")
        fake.responseMap["file.list"] = [entry("Loaded.swift")]
        await store.start(workspaceId: "workspace")
        #expect(store.rows.map(\.path) == ["src", "src/Loaded.swift"])
    }
}
