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
        #expect(ws?.diffSummaryTotalFiles == 5)
        #expect(ws?.taskStatsTotal == 10)
        #expect(ws?.taskStatsCompleted == 3)
        #expect(ws?.taskStatsInProgress == 2)
    }

    @Test func parseMinimalWorkspace() async throws {
        let dict: [String: Any] = ["id": "ws-2", "title": "Minimal"]
        let ws = WorkspaceStore.parseWorkspace(dict)
        #expect(ws != nil)
        #expect(ws?.id == "ws-2")
        #expect(ws?.title == "Minimal")
        #expect(ws?.branch == nil)
        #expect(ws?.prStatus == nil)
        #expect(ws?.diffSummaryTotalFiles == nil)
        #expect(ws?.taskStatsTotal == nil)
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

