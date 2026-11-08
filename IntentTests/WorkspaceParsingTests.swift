import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceParsingTests {
    @Test func parseCompleteWorkspace() {
        let dict: [String: Any] = [
            "id": "ws-1",
            "title": "My Workspace",
            "branch": "feature/login",
            "baseRef": "main",
            "status": "Active",
            "lastActivity": "2026-03-15T10:00:00Z",
            "createdAt": "2026-03-01T09:00:00Z",
            "updatedAt": "2026-03-15T10:30:00Z",
            "repositoryOwner": "acme",
            "repositoryName": "app",
            "prStatus": "Open",
            "prNumber": 42,
            "displayStatus": "pr_open",
            "attention": "unread",
            "waiting": true,
            "diffSummary": ["totalFiles": 5],
            "taskStats": ["total": 10, "completed": 3, "inProgress": 2],
            "statusImageAssetId": "m1abc-deadbeef.png"
        ]
        let workspace = WorkspaceStore.parseWorkspace(dict)
        #expect(workspace != nil)
        #expect(workspace?.id == "ws-1")
        #expect(workspace?.statusImageAssetId == "m1abc-deadbeef.png")
        #expect(workspace?.title == "My Workspace")
        #expect(workspace?.branch == "feature/login")
        #expect(workspace?.baseRef == "main")
        #expect(workspace?.status == "Active")
        #expect(workspace?.lastActivity == "2026-03-15T10:00:00Z")
        #expect(workspace?.createdAt == "2026-03-01T09:00:00Z")
        #expect(workspace?.updatedAt == "2026-03-15T10:30:00Z")
        #expect(workspace?.repositoryOwner == "acme")
        #expect(workspace?.repositoryName == "app")
        #expect(workspace?.prStatus == "Open")
        #expect(workspace?.prNumber == 42)
        #expect(workspace?.displayStatus == "pr_open")
        #expect(workspace?.attention == "unread")
        #expect(workspace?.waiting == true)
        #expect(workspace?.diffSummaryTotalFiles == 5)
        #expect(workspace?.taskStatsTotal == 10)
        #expect(workspace?.taskStatsCompleted == 3)
        #expect(workspace?.taskStatsInProgress == 2)
    }

    @Test func parseNeedsAttentionDisplayStatus() {
        // "needs_attention" is a known wire value: it parses verbatim and
        // resolves to .needsAttention (no fallback to .notStarted).
        let dict: [String: Any] = ["id": "ws-6", "title": "Attention", "displayStatus": "needs_attention"]
        let workspace = WorkspaceStore.parseWorkspace(dict)
        #expect(workspace != nil)
        #expect(workspace?.displayStatus == "needs_attention")
        #expect(workspace.map { resolveDisplayStatus(for: $0) } == .needsAttention)
    }

    @Test func parseUnknownDisplayStatusTolerated() {
        // Unknown future wire values are kept as-is; mapping to the enum
        // happens at display time and lands on the neutral `.unknown`.
        let dict: [String: Any] = ["id": "ws-4", "title": "Future", "displayStatus": "some_future_status"]
        let workspace = WorkspaceStore.parseWorkspace(dict)
        #expect(workspace != nil)
        #expect(workspace?.displayStatus == "some_future_status")
        #expect(workspace.map { resolveDisplayStatus(for: $0) } == .unknown)
    }

    @Test func parseMinimalWorkspace() {
        let dict: [String: Any] = ["id": "ws-2", "title": "Minimal"]
        let workspace = WorkspaceStore.parseWorkspace(dict)
        #expect(workspace != nil)
        #expect(workspace?.id == "ws-2")
        #expect(workspace?.title == "Minimal")
        #expect(workspace?.branch == nil)
        #expect(workspace?.createdAt == nil)
        #expect(workspace?.displayStatus == nil)
        #expect(workspace?.attention == nil)
        #expect(workspace?.waiting == false)
        #expect(workspace?.prStatus == nil)
        #expect(workspace?.diffSummaryTotalFiles == nil)
        #expect(workspace?.taskStatsTotal == nil)
        #expect(workspace?.statusImageAssetId == nil)
    }

    @Test func parseStatusImageAssetIdTreatsBlankAsUnset() {
        // The daemon omits the field until an agent sets one and folds a
        // blank string to a clear (PROTOCOL §5.1 `statusImageAssetId`); the
        // parser mirrors that so the views never render an empty asset id.
        let blank = WorkspaceStore.parseWorkspace(
            ["id": "ws-s1", "title": "S", "statusImageAssetId": "   "]
        )
        #expect(blank?.statusImageAssetId == nil)

        let empty = WorkspaceStore.parseWorkspace(
            ["id": "ws-s2", "title": "S", "statusImageAssetId": ""]
        )
        #expect(empty?.statusImageAssetId == nil)

        let null = WorkspaceStore.parseWorkspace(
            ["id": "ws-s3", "title": "S", "statusImageAssetId": NSNull()]
        )
        #expect(null?.statusImageAssetId == nil)
    }

    @Test func decodeStatusImageAssetIdViaJSONDecoder() throws {
        let decoder = JSONDecoder()

        let present = try decoder.decode(
            Workspace.self,
            from: Data(#"{"id": "ws-i1", "title": "W", "statusImageAssetId": "a1-b2.png"}"#.utf8)
        )
        #expect(present.statusImageAssetId == "a1-b2.png")

        let absent = try decoder.decode(
            Workspace.self,
            from: Data(#"{"id": "ws-i2", "title": "W"}"#.utf8)
        )
        #expect(absent.statusImageAssetId == nil)
    }

    @Test func parseWaitingField() {
        // Present-true, present-false, and absent (⇒ false — the wire omits
        // the field when false, and older daemons never send it).
        let waitingTrue = WorkspaceStore.parseWorkspace(
            ["id": "ws-w1", "title": "W", "waiting": true]
        )
        #expect(waitingTrue?.waiting == true)

        let waitingFalse = WorkspaceStore.parseWorkspace(
            ["id": "ws-w2", "title": "W", "waiting": false]
        )
        #expect(waitingFalse?.waiting == false)

        let waitingAbsent = WorkspaceStore.parseWorkspace(
            ["id": "ws-w3", "title": "W"]
        )
        #expect(waitingAbsent?.waiting == false)
    }

    @Test func decodeWaitingViaJSONDecoder() throws {
        // The Decodable conformance must honor the same absent ⇒ false
        // contract as parseWorkspace (PROTOCOL §5.1: the wire omits the
        // field when false), so a future JSONDecoder path can't throw
        // keyNotFound on the common not-waiting row shape.
        let decoder = JSONDecoder()

        let absent = try decoder.decode(
            Workspace.self,
            from: Data(#"{"id": "ws-d1", "title": "W"}"#.utf8)
        )
        #expect(absent.waiting == false)

        let present = try decoder.decode(
            Workspace.self,
            from: Data(#"{"id": "ws-d2", "title": "W", "waiting": true}"#.utf8)
        )
        #expect(present.waiting == true)
    }

    @Test func decodeCreatedAtViaJSONDecoder() throws {
        let decoder = JSONDecoder()

        let present = try decoder.decode(
            Workspace.self,
            from: Data(#"{"id": "ws-c1", "title": "W", "createdAt": "2026-03-01T09:00:00Z"}"#.utf8)
        )
        #expect(present.createdAt == "2026-03-01T09:00:00Z")

        let absent = try decoder.decode(
            Workspace.self,
            from: Data(#"{"id": "ws-c2", "title": "W"}"#.utf8)
        )
        #expect(absent.createdAt == nil)
    }

    @Test func parsePullRequests() throws {
        // Present array: full row, minimal row, and a malformed row missing
        // the required `number` (skipped — lenient dict-path parse).
        let dict: [String: Any] = [
            "id": "ws-pr1",
            "title": "PRs",
            "pullRequests": [
                [
                    "id": "pr-1",
                    "number": 42,
                    "title": "feat: add thing",
                    "url": "https://github.com/acme/app/pull/42",
                    "status": "Open",
                    "createdAt": "2026-08-01T10:00:00Z",
                    "updatedAt": "2026-08-02T10:00:00Z"
                ] as [String: Any],
                ["number": 43, "status": "Draft"] as [String: Any],
                ["status": "Open"] as [String: Any]
            ]
        ]
        let workspace = try #require(WorkspaceStore.parseWorkspace(dict))
        let pullRequests = workspace.pullRequests
        #expect(pullRequests.count == 2)
        #expect(pullRequests[0].number == 42)
        #expect(pullRequests[0].title == "feat: add thing")
        #expect(pullRequests[0].url == "https://github.com/acme/app/pull/42")
        #expect(pullRequests[0].status == "Open")
        #expect(pullRequests[0].createdAt == "2026-08-01T10:00:00Z")
        #expect(pullRequests[0].updatedAt == "2026-08-02T10:00:00Z")
        #expect(pullRequests[1].number == 43)
        #expect(pullRequests[1].status == "Draft")
        #expect(pullRequests[1].title == nil)
    }

    @Test func parseAbsentPullRequestsYieldsUnreportedEmptyPool() {
        let workspace = WorkspaceStore.parseWorkspace(["id": "ws-pr2", "title": "No PRs"])
        #expect(workspace != nil)
        #expect(workspace?.pullRequests.isEmpty == true)
        #expect(workspace?.pullRequestsWereReported == false)
    }

    @Test func parseUnknownPullRequestStatusKeptRaw() {
        let dict: [String: Any] = [
            "id": "ws-pr3",
            "title": "Future",
            "pullRequests": [["number": 7, "status": "SomeFutureStatus"] as [String: Any]]
        ]
        let workspace = WorkspaceStore.parseWorkspace(dict)
        #expect(workspace?.pullRequests.count == 1)
        #expect(workspace?.pullRequests.first?.status == "SomeFutureStatus")
    }

    @Test func parseActivePullRequest() throws {
        let dict: [String: Any] = [
            "id": "ws-apr1",
            "title": "Active PR",
            "activePullRequest": [
                "id": "pr-1",
                "number": 42,
                "title": "feat: add thing",
                "url": "https://github.com/acme/app/pull/42",
                "status": "Open",
                "createdAt": "2026-08-01T10:00:00Z",
                "updatedAt": "2026-08-02T10:00:00Z"
            ] as [String: Any]
        ]
        let workspace = WorkspaceStore.parseWorkspace(dict)
        let pullRequest = try #require(workspace?.activePullRequest)
        #expect(pullRequest.number == 42)
        #expect(pullRequest.status == "Open")
        #expect(pullRequest.title == "feat: add thing")
        #expect(pullRequest.url == "https://github.com/acme/app/pull/42")
        #expect(pullRequest.createdAt == "2026-08-01T10:00:00Z")
        #expect(pullRequest.updatedAt == "2026-08-02T10:00:00Z")
    }

    @Test func parseAbsentActivePullRequestYieldsNil() {
        let workspace = WorkspaceStore.parseWorkspace(["id": "ws-apr2", "title": "No active PR"])
        #expect(workspace != nil)
        #expect(workspace?.activePullRequest == nil)
    }

    @Test func parseMalformedActivePullRequestDropped() {
        // Missing the required `number` — the lenient wire init rejects it.
        let dict: [String: Any] = [
            "id": "ws-apr3",
            "title": "Malformed",
            "activePullRequest": ["status": "Open"] as [String: Any]
        ]
        let workspace = WorkspaceStore.parseWorkspace(dict)
        #expect(workspace != nil)
        #expect(workspace?.activePullRequest == nil)
    }

    @Test func parseMissingIdReturnsNil() {
        let dict: [String: Any] = ["title": "No ID"]
        #expect(WorkspaceStore.parseWorkspace(dict) == nil)
    }

    @Test func parseMissingTitleReturnsNil() {
        let dict: [String: Any] = ["id": "ws-3"]
        #expect(WorkspaceStore.parseWorkspace(dict) == nil)
    }

    @Test func repositoryNameFallsBackToRepo() {
        let dict: [String: Any] = ["id": "ws-4", "title": "Fallback", "repo": "legacy-repo"]
        let workspace = WorkspaceStore.parseWorkspace(dict)
        #expect(workspace?.repositoryName == "legacy-repo")
    }

    @Test func repositoryNamePreferredOverRepo() {
        let dict: [String: Any] = ["id": "ws-5", "title": "Preferred", "repositoryName": "new-repo", "repo": "old-repo"]
        let workspace = WorkspaceStore.parseWorkspace(dict)
        #expect(workspace?.repositoryName == "new-repo")
    }

    @Test func parseWorkspacesWithWrapper() {
        let result: [String: Any] = [
            "workspaces": [
                ["id": "a", "title": "Alpha"],
                ["id": "b", "title": "Beta"]
            ]
        ]
        let workspaces = WorkspaceStore.parseWorkspaces(from: result)
        #expect(workspaces.count == 2)
        #expect(workspaces[0].id == "a")
        #expect(workspaces[1].id == "b")
    }

    @Test func parseWorkspacesWithPlainArray() {
        let result: [[String: Any]] = [
            ["id": "c", "title": "Charlie"]
        ]
        let workspaces = WorkspaceStore.parseWorkspaces(from: result)
        #expect(workspaces.count == 1)
        #expect(workspaces[0].id == "c")
    }

    @Test func parseWorkspacesWithInvalidInputReturnsEmpty() {
        #expect(WorkspaceStore.parseWorkspaces(from: "invalid").isEmpty)
        #expect(WorkspaceStore.parseWorkspaces(from: [:] as [String: Any]).isEmpty)
        #expect(WorkspaceStore.parseWorkspaces(from: 42).isEmpty)
    }
}
