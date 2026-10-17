import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceFilesStoreTests {
    func entry(_ name: String, directory: Bool = false) -> [String: Any] {
        ["name": name, "type": directory ? "directory" : "file"]
    }

    func paths(_ fake: FakeConnectionManager) -> [String] {
        fake.paramsForMethod("file.list").compactMap { $0["path"] as? String }
    }

    @Test(arguments: ["file", "directory"])
    func gitMetadataIsHiddenWhileOtherDotfilesRemainVisible(_ gitType: String) async {
        let fake = FakeConnectionManager()
        fake.responseQueueMap["file.list"] = [
            [["name": ".git", "type": gitType], entry(".gitignore"), entry(".intent", directory: true)],
            [["name": ".git", "type": gitType], entry(".settings")]
        ]
        let store = WorkspaceFilesStore(connection: fake)
        await store.start(workspaceId: "workspace")
        #expect(store.rows.map(\.path) == [".intent", ".gitignore"])
        await store.toggleDirectory(path: ".intent")
        #expect(store.rows.map(\.path) == [".intent", ".intent/.settings", ".gitignore"])
        #expect(store.entriesByPath.values.flatMap { $0 }.allSatisfy { $0.name != ".git" })
    }

    @Test func rootLoadsOnceAndChildrenLoadOnlyOnExpansion() async {
        let fake = FakeConnectionManager()
        fake.responseQueueMap["file.list"] = [
            [entry("README.md"), entry("src", directory: true)],
            [entry("Main.swift"), entry("nested", directory: true)],
            [entry("Detail.swift")]
        ]
        let store = WorkspaceFilesStore(connection: fake)
        await store.start(workspaceId: "workspace")
        #expect(store.hasLoaded)
        #expect(store.workspaceId == "workspace")
        #expect(store.rows.map(\.path) == ["src", "README.md"])
        #expect(store.rows.map(\.depth) == [0, 0])
        #expect(paths(fake) == ["."])

        await store.toggleDirectory(path: "src")
        #expect(store.rows.map(\.path) == ["src", "src/nested", "src/Main.swift", "README.md"])
        #expect(store.rows.map(\.depth) == [0, 1, 1, 0])
        await store.toggleDirectory(path: "src/nested")
        #expect(store.rows.map(\.path) == ["src", "src/nested", "src/nested/Detail.swift", "src/Main.swift", "README.md"])
        #expect(store.rows.map(\.depth) == [0, 1, 2, 1, 0])
        #expect(paths(fake) == [".", "src", "src/nested"])
        #expect(fake.paramsForMethod("file.list").allSatisfy { $0["workspaceId"] as? String == "workspace" })

        fake.clearRequestLog()
        await store.toggleDirectory(path: "src")
        #expect(store.rows.map(\.path) == ["src", "README.md"])
        #expect(store.entriesByPath["src/nested"]?.first?.name == "Detail.swift")
        await store.start(workspaceId: "workspace")
        await store.toggleDirectory(path: "src")
        #expect(store.expandedPaths == ["src", "src/nested"])
        #expect(store.rows.contains { $0.path == "src/nested/Detail.swift" })
        #expect(paths(fake).isEmpty)
    }

    @Test func emptyRootAndEmptyFolderAreSuccessfulCachedListings() async {
        let fake = FakeConnectionManager()
        fake.responseMap["file.list"] = [] as [[String: Any]]
        let store = WorkspaceFilesStore(connection: fake)
        await store.start(workspaceId: "empty")
        #expect(store.hasLoaded && store.rows.isEmpty)
        #expect(store.errorsByPath.isEmpty && store.loadingPaths.isEmpty)

        fake.responseMap["file.list"] = [entry("empty", directory: true)]
        await store.start(workspaceId: "other")
        fake.responseMap["file.list"] = [] as [[String: Any]]
        await store.toggleDirectory(path: "empty")
        #expect(store.entriesByPath["empty"]?.isEmpty == true)
        #expect(store.expandedPaths == ["empty"])
        #expect(store.rows.map(\.path) == ["empty"])
        fake.clearRequestLog()
        await store.toggleDirectory(path: "empty")
        await store.toggleDirectory(path: "empty")
        #expect(paths(fake).isEmpty)
    }

    @Test func rootAndFolderFailuresCanBeRetriedWithoutLosingGoodRows() async {
        let fake = FakeConnectionManager()
        fake.responseMap["file.list"] = ["invalid": true]
        let store = WorkspaceFilesStore(connection: fake)
        await store.start(workspaceId: "workspace")
        #expect(store.hasLoaded == false)
        #expect(store.errorsByPath["."] != nil)
        #expect(store.loadingPaths.isEmpty)

        fake.responseMap["file.list"] = [entry("src", directory: true)]
        await store.retry(path: ".")
        #expect(store.hasLoaded && store.errorsByPath.isEmpty)
        fake.errorMap["file.list"] = URLError(.notConnectedToInternet)
        fake.clearRequestLog()
        await store.toggleDirectory(path: "src")
        #expect(store.errorsByPath["src"] != nil)
        #expect(store.entriesByPath["src"] == nil)
        #expect(store.expandedPaths == ["src"])
        #expect(store.rows.map(\.path) == ["src"])
        #expect(paths(fake) == ["src"])

        fake.errorMap.removeValue(forKey: "file.list")
        fake.responseMap["file.list"] = [entry("Recovered.swift")]
        await store.retry(path: "src")
        #expect(store.rows.map(\.path) == ["src", "src/Recovered.swift"])
        #expect(store.errorsByPath.isEmpty)
        fake.responseMap["file.list"] = [["name": "invalid"]]
        await store.retry(path: "src")
        #expect(store.rows.map(\.path) == ["src", "src/Recovered.swift"])
        #expect(store.errorsByPath["src"] != nil)
        #expect(store.loadingPaths.isEmpty)
    }

    @Test func refreshReloadsExpandedBranchesButLeavesCollapsedCachesAlone() async {
        let fake = FakeConnectionManager()
        let root = [entry("src", directory: true)]
        let children = [entry("nested", directory: true)]
        fake.responseQueueMap["file.list"] = [root, children, [entry("Old.swift")]]
        let store = WorkspaceFilesStore(connection: fake)
        await store.start(workspaceId: "workspace")
        await store.toggleDirectory(path: "src")
        await store.toggleDirectory(path: "src/nested")
        fake.clearRequestLog()
        fake.responseQueueMap["file.list"] = [root, children, [entry("New.swift")]]
        await store.refresh()
        #expect(paths(fake) == [".", "src", "src/nested"])
        #expect(store.rows.map(\.path) == ["src", "src/nested", "src/nested/New.swift"])
        #expect(store.expandedPaths == ["src", "src/nested"])

        await store.toggleDirectory(path: "src")
        fake.clearRequestLog()
        fake.responseMap["file.list"] = root
        await store.refresh()
        #expect(paths(fake) == ["."])
        #expect(store.entriesByPath["src/nested"]?.first?.name == "New.swift")
        #expect(store.expandedPaths == ["src/nested"])
    }

    @Test func refreshPrunesRemovedFoldersAndFoldersReplacedByFiles() async {
        let fake = FakeConnectionManager()
        fake.responseQueueMap["file.list"] = [
            [entry("src", directory: true), entry("src-old", directory: true)],
            [entry("nested", directory: true)],
            [entry("File.swift")]
        ]
        let store = WorkspaceFilesStore(connection: fake)
        await store.start(workspaceId: "workspace")
        await store.toggleDirectory(path: "src")
        await store.toggleDirectory(path: "src/nested")
        fake.responseMap["file.list"] = [entry("src"), entry("src-old", directory: true)]
        await store.refresh()
        #expect(store.rows.map(\.path) == ["src-old", "src"])
        #expect(store.entriesByPath["src"] == nil && store.entriesByPath["src/nested"] == nil)
        #expect(store.expandedPaths.isEmpty)
        #expect(store.errorsByPath.isEmpty)
        fake.clearRequestLog()
        await store.toggleDirectory(path: "src")
        await store.toggleDirectory(path: "missing")
        await store.retry(path: "../outside")
        #expect(paths(fake).isEmpty)
    }
}
