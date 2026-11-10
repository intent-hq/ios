import Foundation
@testable import Intent
import Testing

@MainActor
struct PullRequestDetailTests {
    @Test func patchHunksNumberLinesAndSkipNoNewlineMarkers() {
        let patch = """
        @@ -3,3 +3,4 @@ func a() {
         keep
        -old
        +new
        +added
        \\ No newline at end of file
        @@ -20 +21 @@
        -x
        +y
        """
        let hunks = WorkspaceDiffBuilder.hunks(patch: patch)
        #expect(hunks.count == 2)
        #expect(hunks[0].lines.map(\.type) == [.context, .deletion, .addition, .addition])
        #expect(hunks[0].lines.map(\.oldNumber) == [3, 4, nil, nil])
        #expect(hunks[0].lines.map(\.newNumber) == [3, nil, 4, 5])
        #expect(hunks[1].oldLines == 1)
        #expect(hunks[1].lines.map(\.newNumber) == [nil, 21])
    }

    @Test func checksSummaryLeadsWithTheWorstOutcome() {
        let passed = PullRequestCheck(name: "a", state: .success)
        let pending = PullRequestCheck(name: "b", state: .pending)
        let failed = PullRequestCheck(name: "c", state: .cancelled)
        #expect(PullRequestCheck.summary([passed, passed])?.label == "2 Passed")
        #expect(PullRequestCheck.summary([passed, pending])?.label == "1 Pending")
        #expect(PullRequestCheck.summary([passed, pending, failed])?.state == .failure)
        #expect(PullRequestCheck.summary([]) == nil)
    }

    @Test func reviewersKeepEachAuthorsLatestVerdictThenUnreviewedRequests() {
        let rows = PullRequestReviewer.rows(
            reviews: [
                ["author": "mona", "state": "CHANGES_REQUESTED"],
                ["author": "hubot", "state": "COMMENTED"],
                ["author": "mona", "state": "APPROVED"]
            ],
            requested: ["mona", "octocat"]
        )
        #expect(rows.map(\.login) == ["mona", "hubot", "octocat"])
        #expect(rows.map(\.verdict) == ["Approved", "Commented", "Requested"])
    }
    @Test func malformedDetailReplyIsAnErrorNotAnEmptyDetail() async {
        let connection = FakeConnectionManager()
        connection.responseQueueMap["github.pulls.get"] = [
            ["pull": "unexpected"],
            ["pull": ["number": 7, "title": "Fix", "state": "open", "body": "Done"]]
        ]
        let store = PullRequestDetailStore(item: PullRequestListItem(owner: "acme", repo: "app", number: 7, title: ""), connection: connection)

        await store.load(.detail)

        #expect(store.detail == nil)
        #expect(store.errors[.detail] == PullRequestDetailStore.ResponseError.malformed.localizedDescription)

        await store.load(.detail)

        #expect(store.detail?.body == "Done")
        #expect(store.errors[.detail] == nil)
    }

    @Test func failedDetailRequestIsAnError() async {
        let connection = FakeConnectionManager()
        connection.errorMap["github.pulls.get"] = URLError(.notConnectedToInternet)
        let store = PullRequestDetailStore(item: PullRequestListItem(owner: "acme", repo: "app", number: 7, title: ""), connection: connection)

        await store.load(.detail)

        #expect(store.detail == nil)
        #expect(store.errors[.detail] != nil)
    }

    @Test func loadAllPopulatesAllFourSectionsAndPreservesExistingItemMetadata() async {
        let connection = FakeConnectionManager()
        connection.responseMap["github.pulls.get"] = [
            "pull": [
                "number": 7,
                "title": "feat: add audit",
                "state": "open",
                "body": "Summary body",
                "headRefName": "feat/audit",
                "baseRefName": "main"
            ] as [String: Any]
        ]
        connection.responseMap["github.pulls.checks"] = [
            "checks": [["name": "CI", "state": "SUCCESS"]],
            "requestedReviewers": ["stale-from-checks"]
        ]
        connection.responseMap["github.pulls.reviews"] = [
            "reviews": [["author": "mona", "state": "APPROVED"]],
            "requestedReviewers": ["octocat"]
        ]
        connection.responseMap["github.pulls.files"] = [
            "files": [["filename": "Intent/App.swift", "status": "modified", "additions": 10, "deletions": 2]],
            "nextToken": "page-2"
        ]
        let initial = PullRequestListItem(
            owner: "acme",
            repo: "app",
            number: 7,
            title: "",
            author: "sambreed"
        )
        let store = PullRequestDetailStore(item: initial, connection: connection)

        await store.loadAll()

        #expect(store.loading.isEmpty)
        #expect(store.errors.isEmpty)
        #expect(store.item.title == "feat: add audit")
        #expect(store.item.author == "sambreed", "filling(from:) must preserve list-level fields absent from pulls.get")
        #expect(store.detail?.body == "Summary body")
        #expect(store.checks.map(\.name) == ["CI"])
        #expect(store.reviewers.map(\.login) == ["mona", "octocat"], "reviews requestedReviewers wins over checks fallback")
        #expect(store.files.map(\.path) == ["Intent/App.swift"])
        #expect(store.filesTruncated)
    }

    @Test func partialSectionFailureIsolatesErrorAndAllowsIndependentRetry() async {
        let connection = FakeConnectionManager()
        connection.responseMap["github.pulls.get"] = [
            "pull": ["number": 7, "title": "Fix", "state": "open", "body": "Body"]
        ]
        connection.errorMap["github.pulls.checks"] = URLError(.timedOut)
        connection.responseMap["github.pulls.reviews"] = ["reviews": []]
        connection.responseMap["github.pulls.files"] = ["files": [], "truncated": false]
        let store = PullRequestDetailStore(
            item: PullRequestListItem(owner: "acme", repo: "app", number: 7, title: "Fix"),
            connection: connection
        )

        await store.loadAll()

        #expect(store.detail?.body == "Body")
        #expect(store.errors[.checks] != nil)
        #expect(store.errors[.detail] == nil)
        #expect(store.errors[.files] == nil)
        #expect(!store.filesTruncated)

        connection.errorMap.removeValue(forKey: "github.pulls.checks")
        connection.responseMap["github.pulls.checks"] = [
            "checks": [["name": "lint", "state": "SUCCESS"]]
        ]
        await store.load(.checks)

        #expect(store.errors[.checks] == nil)
        #expect(store.checks.map(\.name) == ["lint"])
    }
}
