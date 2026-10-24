import Foundation
@testable import Intent
import Testing

@MainActor
struct PullRequestListStoreTests {
    private func repos(_ count: Int) -> [PullRequestListRepository] {
        (0..<count).map { PullRequestListRepository(owner: "acme", name: "repo\($0)") }
    }

    private func pull(_ number: Int, updatedAt: String = "2026-10-01T00:00:00Z") -> [String: Any] {
        ["number": number, "title": "PR \(number)", "state": "open", "updatedAt": updatedAt]
    }

    @Test func wireStateMapsMergedThenClosedThenDraft() {
        let merged = PullRequestListItem(wire: ["number": 1, "title": "a", "state": "closed", "merged": true], owner: "o", repo: "r")
        let closed = PullRequestListItem(wire: ["number": 2, "title": "b", "state": "closed", "draft": true], owner: "o", repo: "r")
        let draft = PullRequestListItem(wire: ["number": 3, "title": "c", "state": "open", "draft": true], owner: "o", repo: "r")
        let open = PullRequestListItem(wire: ["number": 4, "title": "d", "state": "open", "repo": "other"], owner: "o", repo: "r")
        #expect(merged?.status == .merged)
        #expect(closed?.status == .closed)
        #expect(draft?.status == .draft)
        #expect(open?.status == .open)
        #expect(open?.id == "o/other#4")
        #expect(PullRequestListItem(wire: ["title": "missing number"], owner: "o", repo: "r") == nil)
    }

    @Test func linksWorkspacesByPullURLOrOwnRepository() {
        let byURL = Workspace(
            id: "ws-url", title: "URL", branch: nil, baseRef: nil, status: nil, activity: nil, displayStatus: nil,
            repositoryOwner: "acme", repositoryName: "app",
            pullRequests: [WorkspacePullRequest(number: 7, status: "Open", url: "https://github.com/Acme/Lib/pull/7")]
        )
        let byRepo = Workspace(
            id: "ws-repo", title: "Repo", branch: nil, baseRef: nil, status: nil, activity: nil, displayStatus: nil,
            repositoryOwner: "Acme", repositoryName: "App",
            activePullRequest: WorkspacePullRequest(number: 9, status: "Open")
        )
        let links = PullRequestListItem.linkedWorkspaces([byURL, byRepo])
        #expect(links["acme/lib#7"]?.id == "ws-url")
        #expect(links["acme/app#9"]?.id == "ws-repo")
        #expect(links["acme/app#7"] == nil)
    }

    @Test func scopeDeduplicatesRepositoriesCaseInsensitively() {
        let pairs: [(String?, String)] = [("Acme", "App"), ("acme", "app"), ("acme", "lib"), (nil, "local")]
        let workspaces = pairs.enumerated().map { index, repo in
            Workspace(
                id: "ws-\(index)", title: "", branch: nil, baseRef: nil, status: nil, activity: nil, displayStatus: nil,
                repositoryOwner: repo.0, repositoryName: repo.1
            )
        }
        #expect(PullRequestListRepository.scope(workspaces).map(\.name) == ["App", "lib"])
    }

    @Test func loadBatchesRepositoriesAndSortsNewestFirst() async {
        let connection = FakeConnectionManager()
        connection.responseMap["github.authStatus"] = ["isConfigured": true]
        connection.responseQueueMap["github.pulls.search"] = [
            ["pulls": [pull(1, updatedAt: "2026-10-01T00:00:00Z")], "nextToken": "next"],
            ["pulls": [pull(2, updatedAt: "2026-10-02T00:00:00Z")]]
        ]
        let store = PullRequestListStore(connection: connection)
        let query = PullRequestListStore.Query(repositories: repos(7), filter: .reviewRequested, showsClosed: true, text: " fix ")

        await store.load(query)

        let searches = connection.requestLog.filter { $0.method == "github.pulls.search" }
        #expect(searches.count == 2)
        #expect((searches[0].params["repos"] as? [[String: String]])?.count == 5)
        #expect(searches[1].params["repo"] as? String == "repo6")
        #expect(searches[0].params["filter"] as? String == "review-requested")
        #expect(searches[0].params["state"] as? String == "closed")
        #expect(searches[0].params["query"] as? String == "fix")
        #expect(store.items.map(\.number) == [2, 1])
        #expect(store.phase == .ready)
        #expect(store.hasMore)
    }

    @Test func loadMoreOnlyRequestsBatchesWithCursors() async {
        let connection = FakeConnectionManager()
        connection.responseMap["github.authStatus"] = ["isConfigured": true]
        connection.responseQueueMap["github.pulls.search"] = [
            ["pulls": [pull(1, updatedAt: "2026-10-03T00:00:00Z")]],
            ["pulls": [pull(2, updatedAt: "2026-10-02T00:00:00Z")], "nextToken": "page-2"],
            ["pulls": [pull(2, updatedAt: "2026-10-02T00:00:00Z"), pull(3)]]
        ]
        let store = PullRequestListStore(connection: connection)

        await store.load(PullRequestListStore.Query(repositories: repos(12)))
        await store.loadMore()

        let searches = connection.requestLog.filter { $0.method == "github.pulls.search" }
        #expect(searches.count == 3)
        #expect(searches[2].params["repo"] as? String == "repo6")
        #expect(searches[2].params["nextToken"] as? String == "page-2")
        #expect(store.items.map(\.number) == [1, 2, 3])
        #expect(!store.hasMore)
    }

    @Test func unconfiguredGitHubIsDisconnectedWithoutSearching() async {
        let connection = FakeConnectionManager()
        connection.responseMap["github.authStatus"] = ["isConfigured": false]
        let store = PullRequestListStore(connection: connection)

        await store.load(PullRequestListStore.Query(repositories: repos(1)))

        #expect(store.phase == .disconnected)
        #expect(!connection.requestLog.contains { $0.method == "github.pulls.search" })
    }
}
