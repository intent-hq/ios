import Foundation
import Testing
@testable import Intent

@MainActor
struct WorkspaceParsingTests {
    @Test func parseCompleteWorkspace() async throws {
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
        let ws = WorkspaceStore.parseWorkspace(dict)
        #expect(ws != nil)
        #expect(ws?.id == "ws-1")
        #expect(ws?.statusImageAssetId == "m1abc-deadbeef.png")
        #expect(ws?.title == "My Workspace")
        #expect(ws?.branch == "feature/login")
        #expect(ws?.baseRef == "main")
        #expect(ws?.status == "Active")
        #expect(ws?.lastActivity == "2026-03-15T10:00:00Z")
        #expect(ws?.createdAt == "2026-03-01T09:00:00Z")
        #expect(ws?.updatedAt == "2026-03-15T10:30:00Z")
        #expect(ws?.repositoryOwner == "acme")
        #expect(ws?.repositoryName == "app")
        #expect(ws?.prStatus == "Open")
        #expect(ws?.prNumber == 42)
        #expect(ws?.displayStatus == "pr_open")
        #expect(ws?.attention == "unread")
        #expect(ws?.waiting == true)
        #expect(ws?.diffSummaryTotalFiles == 5)
        #expect(ws?.taskStatsTotal == 10)
        #expect(ws?.taskStatsCompleted == 3)
        #expect(ws?.taskStatsInProgress == 2)
    }

    @Test func parseNeedsAttentionDisplayStatus() async throws {
        // "needs_attention" is a known wire value: it parses verbatim and
        // resolves to .needsAttention (no fallback to .notStarted).
        let dict: [String: Any] = ["id": "ws-6", "title": "Attention", "displayStatus": "needs_attention"]
        let ws = WorkspaceStore.parseWorkspace(dict)
        #expect(ws != nil)
        #expect(ws?.displayStatus == "needs_attention")
        #expect(ws.map { resolveDisplayStatus(for: $0) } == .needsAttention)
    }

    @Test func parseUnknownDisplayStatusTolerated() async throws {
        // Unknown future wire values are kept as-is; mapping to the enum
        // happens at display time and lands on the neutral `.unknown`.
        let dict: [String: Any] = ["id": "ws-4", "title": "Future", "displayStatus": "some_future_status"]
        let ws = WorkspaceStore.parseWorkspace(dict)
        #expect(ws != nil)
        #expect(ws?.displayStatus == "some_future_status")
        #expect(ws.map { resolveDisplayStatus(for: $0) } == .unknown)
    }

    @Test func parseMinimalWorkspace() async throws {
        let dict: [String: Any] = ["id": "ws-2", "title": "Minimal"]
        let ws = WorkspaceStore.parseWorkspace(dict)
        #expect(ws != nil)
        #expect(ws?.id == "ws-2")
        #expect(ws?.title == "Minimal")
        #expect(ws?.branch == nil)
        #expect(ws?.createdAt == nil)
        #expect(ws?.displayStatus == nil)
        #expect(ws?.attention == nil)
        #expect(ws?.waiting == false)
        #expect(ws?.prStatus == nil)
        #expect(ws?.diffSummaryTotalFiles == nil)
        #expect(ws?.taskStatsTotal == nil)
        #expect(ws?.statusImageAssetId == nil)
    }

    @Test func parseStatusImageAssetIdTreatsBlankAsUnset() async throws {
        // The daemon omits the field until an agent sets one and folds a
        // blank string to a clear (PROTOCOL §5.1 `statusImageAssetId`); the
        // parser mirrors that so the views never render an empty asset id.
        let blank = WorkspaceStore.parseWorkspace(
            ["id": "ws-s1", "title": "S", "statusImageAssetId": "   "])
        #expect(blank?.statusImageAssetId == nil)

        let empty = WorkspaceStore.parseWorkspace(
            ["id": "ws-s2", "title": "S", "statusImageAssetId": ""])
        #expect(empty?.statusImageAssetId == nil)

        let null = WorkspaceStore.parseWorkspace(
            ["id": "ws-s3", "title": "S", "statusImageAssetId": NSNull()])
        #expect(null?.statusImageAssetId == nil)
    }

    @Test func decodeStatusImageAssetIdViaJSONDecoder() async throws {
        let decoder = JSONDecoder()

        let present = try decoder.decode(
            Workspace.self,
            from: Data(#"{"id": "ws-i1", "title": "W", "statusImageAssetId": "a1-b2.png"}"#.utf8))
        #expect(present.statusImageAssetId == "a1-b2.png")

        let absent = try decoder.decode(
            Workspace.self,
            from: Data(#"{"id": "ws-i2", "title": "W"}"#.utf8))
        #expect(absent.statusImageAssetId == nil)
    }

    @Test func parseWaitingField() async throws {
        // Present-true, present-false, and absent (⇒ false — the wire omits
        // the field when false, and older daemons never send it).
        let waitingTrue = WorkspaceStore.parseWorkspace(
            ["id": "ws-w1", "title": "W", "waiting": true])
        #expect(waitingTrue?.waiting == true)

        let waitingFalse = WorkspaceStore.parseWorkspace(
            ["id": "ws-w2", "title": "W", "waiting": false])
        #expect(waitingFalse?.waiting == false)

        let waitingAbsent = WorkspaceStore.parseWorkspace(
            ["id": "ws-w3", "title": "W"])
        #expect(waitingAbsent?.waiting == false)
    }

    @Test func decodeWaitingViaJSONDecoder() async throws {
        // The Decodable conformance must honor the same absent ⇒ false
        // contract as parseWorkspace (PROTOCOL §5.1: the wire omits the
        // field when false), so a future JSONDecoder path can't throw
        // keyNotFound on the common not-waiting row shape.
        let decoder = JSONDecoder()

        let absent = try decoder.decode(
            Workspace.self,
            from: Data(#"{"id": "ws-d1", "title": "W"}"#.utf8))
        #expect(absent.waiting == false)

        let present = try decoder.decode(
            Workspace.self,
            from: Data(#"{"id": "ws-d2", "title": "W", "waiting": true}"#.utf8))
        #expect(present.waiting == true)
    }

    @Test func decodeCreatedAtViaJSONDecoder() async throws {
        let decoder = JSONDecoder()

        let present = try decoder.decode(
            Workspace.self,
            from: Data(#"{"id": "ws-c1", "title": "W", "createdAt": "2026-03-01T09:00:00Z"}"#.utf8))
        #expect(present.createdAt == "2026-03-01T09:00:00Z")

        let absent = try decoder.decode(
            Workspace.self,
            from: Data(#"{"id": "ws-c2", "title": "W"}"#.utf8))
        #expect(absent.createdAt == nil)
    }

    @Test func parsePullRequests() async throws {
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
                    "updatedAt": "2026-08-02T10:00:00Z",
                ] as [String: Any],
                ["number": 43, "status": "Draft"] as [String: Any],
                ["status": "Open"] as [String: Any],
            ]
        ]
        let ws = WorkspaceStore.parseWorkspace(dict)
        let prs = try #require(ws?.pullRequests)
        #expect(prs.count == 2)
        #expect(prs[0].number == 42)
        #expect(prs[0].title == "feat: add thing")
        #expect(prs[0].url == "https://github.com/acme/app/pull/42")
        #expect(prs[0].status == "Open")
        #expect(prs[0].createdAt == "2026-08-01T10:00:00Z")
        #expect(prs[0].updatedAt == "2026-08-02T10:00:00Z")
        #expect(prs[1].number == 43)
        #expect(prs[1].status == "Draft")
        #expect(prs[1].title == nil)
    }

    @Test func parseAbsentPullRequestsYieldsNil() async throws {
        let ws = WorkspaceStore.parseWorkspace(["id": "ws-pr2", "title": "No PRs"])
        #expect(ws != nil)
        #expect(ws?.pullRequests == nil)
    }

    @Test func parseUnknownPullRequestStatusKeptRaw() async throws {
        let dict: [String: Any] = [
            "id": "ws-pr3",
            "title": "Future",
            "pullRequests": [["number": 7, "status": "SomeFutureStatus"] as [String: Any]]
        ]
        let ws = WorkspaceStore.parseWorkspace(dict)
        #expect(ws?.pullRequests?.count == 1)
        #expect(ws?.pullRequests?.first?.status == "SomeFutureStatus")
    }

    @Test func parseActivePullRequest() async throws {
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
                "updatedAt": "2026-08-02T10:00:00Z",
            ] as [String: Any]
        ]
        let ws = WorkspaceStore.parseWorkspace(dict)
        let pr = try #require(ws?.activePullRequest)
        #expect(pr.number == 42)
        #expect(pr.status == "Open")
        #expect(pr.title == "feat: add thing")
        #expect(pr.url == "https://github.com/acme/app/pull/42")
        #expect(pr.createdAt == "2026-08-01T10:00:00Z")
        #expect(pr.updatedAt == "2026-08-02T10:00:00Z")
    }

    @Test func parseAbsentActivePullRequestYieldsNil() async throws {
        let ws = WorkspaceStore.parseWorkspace(["id": "ws-apr2", "title": "No active PR"])
        #expect(ws != nil)
        #expect(ws?.activePullRequest == nil)
    }

    @Test func parseMalformedActivePullRequestDropped() async throws {
        // Missing the required `number` — the lenient wire init rejects it.
        let dict: [String: Any] = [
            "id": "ws-apr3",
            "title": "Malformed",
            "activePullRequest": ["status": "Open"] as [String: Any]
        ]
        let ws = WorkspaceStore.parseWorkspace(dict)
        #expect(ws != nil)
        #expect(ws?.activePullRequest == nil)
    }

    @Test func parseMissingIdReturnsNil() async throws {
        let dict: [String: Any] = ["title": "No ID"]
        #expect(WorkspaceStore.parseWorkspace(dict) == nil)
    }

    @Test func parseMissingTitleReturnsNil() async throws {
        let dict: [String: Any] = ["id": "ws-3"]
        #expect(WorkspaceStore.parseWorkspace(dict) == nil)
    }

    @Test func repositoryNameFallsBackToRepo() async throws {
        let dict: [String: Any] = ["id": "ws-4", "title": "Fallback", "repo": "legacy-repo"]
        let ws = WorkspaceStore.parseWorkspace(dict)
        #expect(ws?.repositoryName == "legacy-repo")
    }

    @Test func repositoryNamePreferredOverRepo() async throws {
        let dict: [String: Any] = ["id": "ws-5", "title": "Preferred", "repositoryName": "new-repo", "repo": "old-repo"]
        let ws = WorkspaceStore.parseWorkspace(dict)
        #expect(ws?.repositoryName == "new-repo")
    }

    @Test func parseWorkspacesWithWrapper() async throws {
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

    @Test func parseWorkspacesWithPlainArray() async throws {
        let result: [[String: Any]] = [
            ["id": "c", "title": "Charlie"]
        ]
        let workspaces = WorkspaceStore.parseWorkspaces(from: result)
        #expect(workspaces.count == 1)
        #expect(workspaces[0].id == "c")
    }

    @Test func parseWorkspacesWithInvalidInputReturnsEmpty() async throws {
        #expect(WorkspaceStore.parseWorkspaces(from: "invalid").isEmpty)
        #expect(WorkspaceStore.parseWorkspaces(from: [:] as [String: Any]).isEmpty)
        #expect(WorkspaceStore.parseWorkspaces(from: 42).isEmpty)
    }
}
