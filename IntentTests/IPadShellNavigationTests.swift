import Foundation
@testable import Intent
import Testing

extension AppCoordinatorTests {
    private enum IPadReference {
        static let largeWidth: CGFloat = 1366
        static let smallWidth: CGFloat = 1210
        static let portraitWidth: CGFloat = 834
        static let windowWidth: CGFloat = 1024
        static let narrowWidth: CGFloat = 320
        static let largeSidebarWidth: CGFloat = 400
        static let smallSidebarWidth: CGFloat = 384
    }

    @Test @MainActor func iPadRailKeepsWorkspaceRouteAndWindowBackend() {
        let connection = FakeConnectionManager()
        let coordinator = iPadCoordinator(connection: connection)
        var retargetedBackends: [BackendID] = []
        coordinator.retargetWindow = { retargetedBackends.append($0) }
        coordinator.onSelectAgent("coder", workspaceId: "workspace", agentName: "Coder")
        let route = coordinator.currentScreenDescription
        let request = coordinator.conversationRequestId

        coordinator.iPadNavigation.collapseSidebar()
        coordinator.onSelectIPadSection(.connections)
        #expect(coordinator.iPadNavigation.isSidebarVisible)
        coordinator.onOpenSettings()

        #expect(coordinator.iPadNavigation.section == .settings)
        #expect(coordinator.iPadNavigation.detail == .workspace)
        #expect(coordinator.currentScreenDescription == route)
        #expect(coordinator.conversationRequestId == request)
        #expect(coordinator.selectedWorkspaceId == "workspace")
        #expect(coordinator.backendID == Self.windowBackend)
        #expect(retargetedBackends.isEmpty)
        #expect(connection.connectLog.isEmpty)
        #expect(connection.disconnectCallCount == 0)
    }

    @Test @MainActor func iPadRailRestoresIndependentAssistantAndWorkspaceSelections() {
        let coordinator = iPadCoordinator(connection: FakeConnectionManager())
        coordinator.onSelectAgent("coder", workspaceId: "workspace", agentName: "Coder")
        let route = coordinator.currentScreenDescription
        coordinator.onSelectAssistant(agentId: "assistant-thread")
        coordinator.onSelectIPadSection(.settings)
        #expect(coordinator.iPadNavigation.detail == .assistant)

        coordinator.onSelectIPadSection(.workspaces)
        #expect(coordinator.iPadNavigation.detail == .workspace)
        #expect(coordinator.currentScreenDescription == route)
        coordinator.onSelectIPadSection(.assistant)
        #expect(coordinator.iPadNavigation.detail == .assistant)
        #expect(coordinator.assistantAgentId == "assistant-thread")
        #expect(coordinator.selectedWorkspaceId == "workspace")
    }

    @Test @MainActor func iPadSeparatePairingRaisesTargetWindowWithoutRedialingOriginal() {
        let connection = FakeConnectionManager()
        let coordinator = iPadCoordinator(connection: connection)
        coordinator.onSelectAgent("coder", workspaceId: "workspace", agentName: "Coder")
        let route = coordinator.currentScreenDescription
        let port = 4242
        let paired = Self.makeConnection(port: port)
        var retargetedBackends: [BackendID] = []
        coordinator.retargetWindow = { retargetedBackends.append($0) }

        coordinator.onIPadPairedConnection(paired)

        #expect(retargetedBackends == [BackendID(paired.id)])
        #expect(coordinator.backendID == Self.windowBackend)
        #expect(coordinator.currentScreenDescription == route)
        #expect(connection.disconnectCallCount == 0)
        #expect(connection.connectLog.isEmpty)
    }

    @Test @MainActor func iPadPairingCancellationRestoresEitherDetailWithoutRouting() {
        let coordinator = iPadCoordinator(connection: FakeConnectionManager())
        coordinator.onSelectAgent("coder", workspaceId: "workspace", agentName: "Coder")
        let route = coordinator.currentScreenDescription
        for detail in [IPadDetailSelection.workspace, .assistant] {
            if detail == .assistant { coordinator.onSelectAssistant(agentId: "assistant-thread") }
            coordinator.onSelectIPadSection(.connections)
            for mode in [IPadPairingMode.qrCode, .manual] {
                coordinator.iPadNavigation.presentPairing(mode)
                coordinator.iPadNavigation.cancelPairing()
                #expect(coordinator.iPadNavigation.pairing == nil)
                #expect(coordinator.iPadNavigation.detail == detail)
                #expect(coordinator.currentScreenDescription == route)
                #expect(coordinator.backendID == Self.windowBackend)
            }
        }
    }

    @Test @MainActor func iPadResizingKeepsDetailAndExplicitCollapsePreference() {
        var state = IPadNavigationState()
        state.showAssistantDetail()
        state.collapseSidebar()
        state.updateLayout(usesOverlay: true)
        #expect(!state.isSidebarVisible)
        state.selectSection(.settings)
        #expect(state.isSidebarVisible)
        #expect(state.detail == .assistant)
        state.updateLayout(usesOverlay: false)
        #expect(!state.isSidebarVisible, "Narrow drawer reveal must not undo explicit wide-window collapse")
        state.revealSidebar()
        state.updateLayout(usesOverlay: true)
        #expect(!state.isSidebarVisible)
        state.updateLayout(usesOverlay: false)
        #expect(state.isSidebarVisible, "Wide-window expansion survives a trip through portrait")
        #expect(state.detail == .assistant)
    }

    @Test @MainActor func iPadWorkspacesRailLeavesSidebarWorkspaceOnlyWhenItIsShown() {
        let coordinator = iPadCoordinator(connection: FakeConnectionManager())
        coordinator.iPadNavigation.updateLayout(usesOverlay: false)
        coordinator.onSelectAgent("coder", workspaceId: "workspace", agentName: "Coder")
        let agentRoute = coordinator.currentScreenDescription
        coordinator.onSelectIPadSection(.settings)
        coordinator.onSelectIPadSection(.workspaces)
        #expect(coordinator.currentScreenDescription == agentRoute)

        coordinator.onSelectIPadSection(.workspaces)
        guard case .workspaceDetail(workspaceId: "workspace") = coordinator.currentScreen else {
            Issue.record("Expected the workspace overview, got \(coordinator.currentScreenDescription)")
            return
        }
        #expect(coordinator.iPadNavigation.isSidebarVisible)

        coordinator.onSelectAgent("coder", workspaceId: "workspace", agentName: "Coder")
        coordinator.iPadNavigation.collapseSidebar()
        coordinator.onSelectIPadSection(.workspaces)
        #expect(coordinator.currentScreenDescription == agentRoute)
    }

    @Test @MainActor func iPadNarrowRowSelectionClosesDrawerIncludingRepeatedAgentSelection() {
        let coordinator = iPadCoordinator(connection: FakeConnectionManager())
        coordinator.iPadNavigation.updateLayout(usesOverlay: true)
        coordinator.onSelectAgent("coder", workspaceId: "workspace", agentName: "Coder")
        coordinator.onSelectIPadSection(.workspaces)
        #expect(coordinator.iPadNavigation.isSidebarVisible)
        coordinator.onSelectAgent("coder", workspaceId: "workspace", agentName: "Coder")
        #expect(!coordinator.iPadNavigation.isSidebarVisible)
        coordinator.onSelectIPadSection(.assistant)
        #expect(coordinator.iPadNavigation.isSidebarVisible)
        coordinator.onSelectAssistant(agentId: "assistant-thread")
        #expect(!coordinator.iPadNavigation.isSidebarVisible)
    }

    @Test @MainActor func iPadAssistantPermissionDoesNotGateWorkspaceNavigation() {
        let connection = FakeConnectionManager()
        let coordinator = iPadCoordinator(connection: connection)
        connection.currentPrincipal = InvitedSessionFixtures.principal(role: .guest)
        coordinator.onSelectIPadSection(.assistant)
        #expect(coordinator.iPadNavigation.detail == .workspace)
        #expect(!coordinator.iPadNavigation.hasOpenedAssistant)
        #expect(!coordinator.canCreateWorkspace)
        coordinator.onSelectIPadSection(.connections)
        coordinator.onSelectIPadSection(.workspaces)
        #expect(coordinator.iPadNavigation.section == .workspaces)
        #expect(coordinator.iPadNavigation.isSidebarVisible)
    }

    @Test @MainActor func iPadAssistantSurvivesReconnectButKnownDemotionEvictsIt() {
        let connection = FakeConnectionManager()
        let coordinator = iPadCoordinator(connection: connection)
        coordinator.onSelectAssistant(agentId: "assistant-thread")
        connection.currentPrincipal = nil
        coordinator.onIPadAssistantAccessChanged()
        #expect(coordinator.iPadNavigation.detail == .assistant)
        connection.currentPrincipal = InvitedSessionFixtures.principal(role: .member)
        coordinator.onIPadAssistantAccessChanged()
        #expect(coordinator.iPadNavigation.detail == .workspace)
        #expect(!coordinator.iPadNavigation.hasOpenedAssistant)
        #expect(coordinator.selectedSection == .workspaces)
    }

    @Test @MainActor func iPadNotificationSelectionExitsSettingsAndTemporaryPairing() {
        let coordinator = iPadCoordinator(connection: FakeConnectionManager())
        coordinator.currentScreen = .workspaceList
        coordinator.onSelectIPadSection(.settings)
        coordinator.iPadNavigation.presentPairing(.qrCode)
        coordinator.handleNotificationSelection(
            agentId: "coder",
            workspaceId: "workspace",
            agentName: "Coder",
            connectionId: Self.windowBackend.connectionID
        )
        #expect(coordinator.iPadNavigation.section == .workspaces)
        #expect(coordinator.iPadNavigation.pairing == nil)
        #expect(coordinator.selectedWorkspaceId == "workspace")
    }

    @Test @MainActor func iPadBackgroundRedirectKeepsSectionAndPairingUntilExplicitSelection() {
        let coordinator = iPadCoordinator(connection: FakeConnectionManager())
        coordinator.onSelectWorkspace("workspace")
        coordinator.onSelectAssistant(agentId: "assistant-thread")
        coordinator.onSelectIPadSection(.settings)
        coordinator.iPadNavigation.presentPairing(.manual)

        coordinator.handleMissingWorkspace()

        guard case .workspaceList = coordinator.currentScreen else {
            Issue.record("Expected .workspaceList, got \(coordinator.currentScreen)")
            return
        }
        #expect(coordinator.iPadNavigation.section == .settings)
        #expect(coordinator.iPadNavigation.detail == .assistant)
        #expect(coordinator.iPadNavigation.pairing == .manual)
        #expect(coordinator.selectedSection == .assistant)

        coordinator.onSelectWorkspace("workspace")
        #expect(coordinator.iPadNavigation.section == .workspaces)
        #expect(coordinator.iPadNavigation.detail == .workspace)
        #expect(coordinator.iPadNavigation.pairing == nil)
        #expect(coordinator.selectedSection == .workspaces)
    }

    @Test @MainActor func iPadLayoutUsesReadablePanesAndAdaptsForTextSize() {
        let large = IPadShellLayout(width: IPadReference.largeWidth, isAccessibilitySize: false)
        let small = IPadShellLayout(width: IPadReference.smallWidth, isAccessibilitySize: false)
        let portrait = IPadShellLayout(width: IPadReference.portraitWidth, isAccessibilitySize: false)
        let window = IPadShellLayout(width: IPadReference.windowWidth, isAccessibilitySize: false)
        let accessibleWindow = IPadShellLayout(width: IPadReference.windowWidth, isAccessibilitySize: true)
        #expect(!large.usesSidebarOverlay)
        #expect(!small.usesSidebarOverlay)
        #expect(portrait.usesSidebarOverlay)
        #expect(!window.usesSidebarOverlay)
        #expect(accessibleWindow.usesSidebarOverlay)
        #expect(large.sidebarWidth == IPadReference.largeSidebarWidth)
        #expect(small.sidebarWidth == IPadReference.smallSidebarWidth)
        #expect(portrait.detailLeadingInset(sidebarVisible: true) == 0)
        let narrow = IPadShellLayout(width: IPadReference.narrowWidth, isAccessibilitySize: true)
        #expect(narrow.sidebarWidth <= narrow.contentWidth)
    }

    @Test(arguments: [true, false]) @MainActor
    func iPadFocusPreservesSidebarPreferenceAndConversation(expanded: Bool) {
        let coordinator = iPadCoordinator(connection: FakeConnectionManager())
        coordinator.onSelectAgent("coder", workspaceId: "workspace", agentName: "Coder")
        if !expanded { coordinator.iPadNavigation.collapseSidebar() }
        let request = coordinator.conversationRequestId
        let route = coordinator.currentScreenDescription
        for presentation in [IPadFocusPresentation.workspaceSearch, .conversationEditing] {
            coordinator.iPadNavigation.setFocusPresentation(presentation)
            #expect(coordinator.iPadNavigation.focusPresentation == presentation)
            coordinator.iPadNavigation.updateLayout(usesOverlay: true)
            #expect(coordinator.iPadNavigation.focusPresentation == presentation)
            coordinator.iPadNavigation.updateLayout(usesOverlay: false)
            coordinator.iPadNavigation.setFocusPresentation(.normal)
            #expect(coordinator.iPadNavigation.isSidebarExpanded == expanded)
            #expect(coordinator.conversationRequestId == request)
            #expect(coordinator.currentScreenDescription == route)
        }
    }

    @Test @MainActor func iPadExplicitSelectionEndsFocusAndPairingCannotEnterIt() {
        var state = IPadNavigationState()
        state.setFocusPresentation(.workspaceSearch)
        state.showWorkspaceDetail()
        #expect(state.focusPresentation == .normal)
        state.setFocusPresentation(.conversationEditing)
        state.showAssistantDetail()
        #expect(state.focusPresentation == .normal)
        state.setFocusPresentation(.workspaceSearch)
        #expect(state.focusPresentation == .normal)
        state.setFocusPresentation(.conversationEditing)
        state.presentPairing(.manual)
        state.setFocusPresentation(.conversationEditing)
        #expect(state.focusPresentation == .normal)
    }

    @Test @MainActor func iPadFocusedPanelFitsTheWindowWithoutReservingRailSpace() {
        for width in [IPadReference.narrowWidth, IPadReference.portraitWidth, IPadReference.largeWidth] {
            let layout = IPadShellLayout(width: width, isAccessibilitySize: true)
            #expect(layout.focusedPanelWidth <= IPadShellLayout.focusPanelWidth)
            #expect(layout.focusedPanelWidth <= layout.availableWidth)
            #expect(layout.focusedPanelLeadingInset >= 0)
            #expect(layout.focusedPanelLeadingInset * 2 + layout.focusedPanelWidth == layout.availableWidth)
        }
    }

    @MainActor private func iPadCoordinator(connection: FakeConnectionManager) -> AppCoordinator {
        connection.connectionState = .connected
        connection.currentPrincipal = InvitedSessionFixtures.principal("owner", role: .owner)
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(connectionManager: connection),
            connection: connection,
            backendID: Self.windowBackend,
            persistence: persistence
        )
        coordinator.usesIPadShell = true
        return coordinator
    }
}
