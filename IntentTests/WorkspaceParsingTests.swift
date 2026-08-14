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
            "repositoryOwner": "acme",
            "repositoryName": "app",
            "prStatus": "Open",
            "prNumber": 42,
            "displayStatus": "pr_open",
            "attention": "unread",
            "waiting": true,
            "diffSummary": ["totalFiles": 5],
            "taskStats": ["total": 10, "completed": 3, "inProgress": 2]
        ]
        let ws = WorkspaceStore.parseWorkspace(dict)
        #expect(ws != nil)
        #expect(ws?.id == "ws-1")
        #expect(ws?.title == "My Workspace")
        #expect(ws?.branch == "feature/login")
        #expect(ws?.baseRef == "main")
        #expect(ws?.status == "Active")
        #expect(ws?.lastActivity == "2026-03-15T10:00:00Z")
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
        #expect(ws?.displayStatus == nil)
        #expect(ws?.attention == nil)
        #expect(ws?.waiting == false)
        #expect(ws?.prStatus == nil)
        #expect(ws?.diffSummaryTotalFiles == nil)
        #expect(ws?.taskStatsTotal == nil)
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

