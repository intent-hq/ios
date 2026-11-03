import Foundation
@testable import Intent
import Testing

extension AppCoordinatorTests {
    @Test @MainActor func workspaceSwipe_opensOverviewBeforeLoadingRecentAgent() async throws {
        let (coordinator, fake) = makeRecentAgentCoordinator()
        fake.pendingMethods.insert("agent.list")

        let opening = coordinator.onOpenRecentWorkspaceAgent("workspace-1")

        #expect(Self.isWorkspaceDetail(coordinator.currentScreen, for: "workspace-1"))
        #expect(coordinator.selectedWorkspaceId == "workspace-1")
        #expect(coordinator.selectedSection == .workspaces)
        #expect(persistence.loadLastScreen(for: Self.windowBackend.connectionID)?.screen == "workspaceDetail")
        try await fake.waitForPendingRequests("agent.list")
        let params = try #require(fake.paramsForMethod("agent.list").first)
        #expect(params["workspaceId"] as? String == "workspace-1")
        #expect(params["scope"] == nil, "Include delegated and background agents in the lookup")
        fake.resolvePending("agent.list", with: [
            "agents": [
                [
                    "id": "whole", "name": "Coordinator", "lastActivity": "2026-10-01T05:00:00Z",
                    "metadata": ["specialist": "spec-writer", "attentionRequestKind": "blocker"]
                ],
                [
                    "id": "recent", "name": "Recent worker", "lastActivity": "2026-10-01T05:00:00.900Z",
                    "parentAgentId": "whole", "metadata": ["isBackground": true]
                ],
                [
                    "id": "retired", "name": "Retired", "lastActivity": "2026-10-01T06:00:00Z",
                    "retiredAt": "2026-10-01T06:00:00Z"
                ]
            ]
        ])
        await opening.value

        if case let .agentConversation(agentId, workspaceId, agentName) = coordinator.currentScreen {
            #expect(agentId == "recent")
            #expect(workspaceId == "workspace-1")
            #expect(agentName == "Recent worker")
        } else {
            Issue.record("Expected the most recently active non-retired agent, got \(coordinator.currentScreen)")
        }
        #expect(coordinator.conversationRequestId == 1)
        #expect(persistence.loadLastScreen(for: Self.windowBackend.connectionID)?.agentId == "recent")
    }

    @Test(arguments: ["updatedAt", "createdAt"])
    @MainActor func workspaceSwipe_usesFallbackActivityTimestamp(timestampKey: String) async {
        let (coordinator, fake) = makeRecentAgentCoordinator()
        fake.responseMap["agent.list"] = [
            "agents": [
                [
                    "id": "old", "name": "Old", "lastActivity": "2026-09-30T05:00:00Z",
                    "updatedAt": "2026-10-02T05:00:00Z"
                ],
                ["id": "recent", "name": "Recent", timestampKey: "2026-10-01T05:00:00Z"],
                ["id": "unknown", "name": "Unknown", "lastActivity": "invalid"]
            ]
        ]

        await coordinator.onOpenRecentWorkspaceAgent("workspace-1").value

        #expect(persistence.loadLastScreen(for: Self.windowBackend.connectionID)?.agentId == "recent")
    }

    @Test(arguments: ["2026-10-01T05:00:00Z", "invalid", ""])
    @MainActor func workspaceSwipe_breaksActivityTiesByAgentId(timestamp: String) async {
        let (coordinator, fake) = makeRecentAgentCoordinator()
        fake.responseMap["agent.list"] = [
            "agents": [
                ["id": "agent-z", "name": "Zulu", "lastActivity": timestamp],
                ["id": "agent-a", "name": "Alpha", "lastActivity": timestamp]
            ]
        ]

        await coordinator.onOpenRecentWorkspaceAgent("workspace-1").value

        #expect(persistence.loadLastScreen(for: Self.windowBackend.connectionID)?.agentId == "agent-a")
    }

    @Test(arguments: ["empty", "retired", "malformed", "error"])
    @MainActor func workspaceSwipe_withoutUsableAgents_keepsOverview(responseKind: String) async {
        let (coordinator, fake) = makeRecentAgentCoordinator()
        switch responseKind {
        case "retired":
            fake.responseMap["agent.list"] = [
                "agents": [["id": "retired", "name": "Retired", "retiredAt": "2026-10-01T05:00:00Z"]]
            ]
        case "malformed": fake.responseMap["agent.list"] = ["agents": "invalid"]
        case "error": fake.errorMap["agent.list"] = NSError(domain: "WebSocket", code: -1)
        default: fake.responseMap["agent.list"] = ["agents": []]
        }

        await coordinator.onOpenRecentWorkspaceAgent("workspace-1").value

        #expect(Self.isWorkspaceDetail(coordinator.currentScreen, for: "workspace-1"))
        #expect(coordinator.conversationRequestId == 0)
        #expect(persistence.loadLastScreen(for: Self.windowBackend.connectionID)?.screen == "workspaceDetail")
    }

    @Test @MainActor func workspaceTap_keepsOverviewWithoutLoadingRecentAgent() async throws {
        let (coordinator, fake) = makeRecentAgentCoordinator()
        fake.responseMap["agent.list"] = ["agents": [["id": "agent-1", "name": "Agent"]]]

        coordinator.onSelectAgent("agent-1", workspaceId: "workspace-1", agentName: "Agent")
        coordinator.onSelectWorkspace("workspace-1")
        // Await the ordinary markSeen request so queued entry work has run.
        try await fake.waitForRequests("workspace.markSeen")

        #expect(Self.isWorkspaceDetail(coordinator.currentScreen, for: "workspace-1"))
        #expect(!fake.didCallMethod("agent.list"))
    }

    @Test(arguments: RecentAgentNavigationChange.allCases)
    @MainActor func workspaceSwipe_ignoresCompletionAfterNavigation(change: RecentAgentNavigationChange) async throws {
        let (coordinator, fake) = makeRecentAgentCoordinator()
        fake.pendingMethods.insert("agent.list")
        let opening = coordinator.onOpenRecentWorkspaceAgent("workspace-1")
        try await fake.waitForPendingRequests("agent.list")

        change.navigate(coordinator)
        let screen = coordinator.currentScreenDescription
        let section = coordinator.selectedSection
        let workspaceId = coordinator.selectedWorkspaceId
        let conversationRequestId = coordinator.conversationRequestId
        fake.resolvePending("agent.list", with: ["agents": [["id": "stale", "name": "Stale"]]])
        await opening.value

        #expect(coordinator.currentScreenDescription == screen)
        #expect(coordinator.selectedSection == section)
        #expect(coordinator.selectedWorkspaceId == workspaceId)
        #expect(coordinator.conversationRequestId == conversationRequestId)
    }

    @Test @MainActor func workspaceSwipe_repeatedSwipeSupersedesEarlierLookup() async throws {
        let (coordinator, fake) = makeRecentAgentCoordinator()
        fake.pendingMethods.insert("agent.list")
        let first = coordinator.onOpenRecentWorkspaceAgent("workspace-1")
        try await fake.waitForPendingRequests("agent.list")
        let second = coordinator.onOpenRecentWorkspaceAgent("workspace-1")
        try await fake.waitForPendingRequests("agent.list", count: 2)

        fake.resolvePending("agent.list", with: ["agents": [["id": "stale", "name": "Stale"]]])
        await first.value
        #expect(Self.isWorkspaceDetail(coordinator.currentScreen, for: "workspace-1"))
        fake.resolvePending("agent.list", with: ["agents": [["id": "current", "name": "Current"]]])
        await second.value

        #expect(persistence.loadLastScreen(for: Self.windowBackend.connectionID)?.agentId == "current")
        #expect(coordinator.conversationRequestId == 1)
    }

    /// Rows ascend by creation, so the most recent agent can sit on a later
    /// `agent.list` page ("Paged agent lists and queues").
    @Test @MainActor func workspaceSwipe_readsEveryAgentPage() async {
        let (coordinator, fake) = makeRecentAgentCoordinator()
        fake.responseQueueMap["agent.list"] = [
            ["agents": [["id": "old", "name": "Old", "lastActivity": "2026-09-30T05:00:00Z"]], "nextToken": "t1"],
            ["agents": [["id": "newest", "name": "Newest", "lastActivity": "2026-10-01T05:00:00Z"]], "nextToken": NSNull()]
        ]

        await coordinator.onOpenRecentWorkspaceAgent("workspace-1").value

        #expect(persistence.loadLastScreen(for: Self.windowBackend.connectionID)?.agentId == "newest")
        let sent = fake.paramsForMethod("agent.list")
        #expect(sent.map { $0["nextToken"] as? String } == [nil, "t1"])
        #expect(sent.allSatisfy { $0["workspaceId"] as? String == "workspace-1" && $0["scope"] == nil })
    }

    @Test @MainActor func workspaceSwipe_pageErrorKeepsOverview() async {
        let (coordinator, fake) = makeRecentAgentCoordinator()
        // The second page has no configured reply, so the walk fails.
        fake.responseQueueMap["agent.list"] = [
            ["agents": [["id": "old", "name": "Old"]], "nextToken": "t1"]
        ]

        await coordinator.onOpenRecentWorkspaceAgent("workspace-1").value

        #expect(Self.isWorkspaceDetail(coordinator.currentScreen, for: "workspace-1"))
        #expect(coordinator.conversationRequestId == 0)
        #expect(fake.paramsForMethod("agent.list").count == 2)
    }

    @Test @MainActor func workspaceSwipe_supersededLookupStopsBeforeItsNextPage() async throws {
        let (coordinator, fake) = makeRecentAgentCoordinator()
        fake.pendingMethods.insert("agent.list")
        let opening = coordinator.onOpenRecentWorkspaceAgent("workspace-1")
        try await fake.waitForPendingRequests("agent.list")

        coordinator.onBackToWorkspaceList()
        fake.resolvePending("agent.list", with: ["agents": [["id": "stale", "name": "Stale"]], "nextToken": "t1"])
        await opening.value

        #expect(fake.paramsForMethod("agent.list").count == 1, "A superseded lookup must not read its next page")
        #expect(coordinator.conversationRequestId == 0)
    }

    @MainActor
    private func makeRecentAgentCoordinator() -> (AppCoordinator, FakeConnectionManager) {
        let fake = FakeConnectionManager()
        fake.responseMap["workspace.markSeen"] = [:]
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true),
            connection: fake,
            backendID: Self.windowBackend,
            persistence: persistence
        )
        return (coordinator, fake)
    }
}

enum RecentAgentNavigationChange: CaseIterable, Sendable {
    case agent
    case anotherWorkspace
    case assistant
    case clearSelection
    case list
    case note
    case returnToSameSection
    case returnToSameWorkspace
    case sameWorkspaceTap
    case settings

    @MainActor
    func navigate(_ coordinator: AppCoordinator) {
        switch self {
        case .agent: coordinator.onSelectAgent("chosen", workspaceId: "workspace-1", agentName: "Chosen")
        case .anotherWorkspace: coordinator.onSelectWorkspace("workspace-2")
        case .assistant: coordinator.selectedSection = .assistant
        case .clearSelection: coordinator.selectedWorkspaceId = nil
        case .list: coordinator.onBackToWorkspaceList()
        case .note: coordinator.onSelectNote("note-1", workspaceId: "workspace-1", noteTitle: "Note")
        case .returnToSameSection:
            coordinator.selectedSection = .assistant
            coordinator.selectedSection = .workspaces
        case .returnToSameWorkspace:
            coordinator.onBackToWorkspaceList()
            coordinator.onSelectWorkspace("workspace-1")
        case .sameWorkspaceTap: coordinator.onSelectWorkspace("workspace-1")
        case .settings: coordinator.onOpenSettings()
        }
    }
}
