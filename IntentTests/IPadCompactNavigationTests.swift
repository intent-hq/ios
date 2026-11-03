import Foundation
@testable import Intent
import SwiftUI
import Testing

@MainActor
struct IPadCompactNavigationTests {
    @Test func miniChatHeaderRequiresASmallIPadDisplay() {
        for size in [CGSize(width: 744, height: 1133), CGSize(width: 768, height: 1024)] {
            for screen in [size, CGSize(width: size.height, height: size.width)] {
                #expect(ConversationHeaderLayout.usesMiniHeader(isPad: true, screenSize: screen))
                #expect(!ConversationHeaderLayout.usesMiniHeader(isPad: false, screenSize: screen))
            }
        }
        let largerDisplays = [
            CGSize(width: 800, height: 1200), CGSize(width: 810, height: 1080), CGSize(width: 820, height: 1180),
            CGSize(width: 834, height: 1194), CGSize(width: 1024, height: 1366)
        ]
        for size in [.zero] + largerDisplays {
            #expect(!ConversationHeaderLayout.usesMiniHeader(isPad: true, screenSize: size))
            #expect(!ConversationHeaderLayout.usesMiniHeader(isPad: true, screenSize: CGSize(width: size.height, height: size.width)))
        }
    }

    @Test func sharedShellRequiresAnIPadOrExpandedDuo() {
        for sizeClass: UserInterfaceSizeClass? in [nil, .compact, .regular] {
            #expect(IPadShellLayout.usesShell(isPad: true, hasVerticalBar: false, sizeClass: sizeClass))
            #expect(!IPadShellLayout.usesShell(isPad: false, hasVerticalBar: false, sizeClass: sizeClass))
            #expect(IPadShellLayout.usesShell(isPad: false, hasVerticalBar: true, sizeClass: sizeClass) == (sizeClass == .regular))
        }
    }

    @Test func unfoldedSidebarLeavesRoomForTheConversation() {
        for width: CGFloat in [932, 1024, 1300] {
            let layout = IPadShellLayout(width: width, isAccessibilitySize: false, usesFoldableLayout: true)
            #expect(!layout.usesSidebarOverlay)
            #expect(layout.sidebarWidth <= IPadShellLayout.smallSidebarWidth)
            #expect(layout.contentWidth - layout.sidebarWidth - layout.gutter >= IPadShellLayout.minimumDetailWidth)
        }
        let portrait = IPadShellLayout(width: 668, isAccessibilitySize: true, usesFoldableLayout: true)
        #expect(portrait.usesSidebarOverlay)
    }

    @Test(arguments: [false, true])
    func oppositeRailEdgesPreserveContentAndNavigation(accessibility: Bool) {
        for width: CGFloat in [480, 668, 932] {
            let trailing = IPadShellLayout(width: width, isAccessibilitySize: accessibility, usesFoldableLayout: true)
            let leading = IPadShellLayout(
                width: width,
                isAccessibilitySize: accessibility,
                usesFoldableLayout: true,
                usesLeadingVerticalBar: true
            )
            #expect(leading.leadingInset == trailing.trailingInset)
            #expect(leading.trailingInset == trailing.leadingInset)
            #expect(leading.contentWidth == trailing.contentWidth)
            #expect(leading.sidebarWidth == trailing.sidebarWidth)
            #expect(leading.usesSidebarOverlay == trailing.usesSidebarOverlay)
            #expect(leading.usesCompactNavigation == trailing.usesCompactNavigation)
        }
    }

    @Test func breakpointReclaimsTheEntireRailAndGutter() {
        let threshold = IPadShellLayout.compactWindowWidth
        for accessibility in [false, true] {
            let compact = IPadShellLayout(width: threshold - 1, isAccessibilitySize: accessibility)
            let rail = IPadShellLayout(width: threshold, isAccessibilitySize: accessibility)
            #expect(compact.usesCompactNavigation)
            #expect(!rail.usesCompactNavigation)
            #expect(compact.usesSidebarOverlay)
            #expect(compact.railGutter == 0)
            #expect(compact.contentWidth == compact.width - 2 * compact.inset)
            #expect(rail.contentWidth == rail.width - 2 * rail.inset - IPadShellLayout.railWidth - rail.gutter)
            #expect(compact.detailLeadingInset(sidebarVisible: true) == 0)
            #expect(compact.sidebarWidth <= compact.contentWidth)
            #expect(compact.sidebarWidth == compact.contentWidth)
        }
    }

    @Test func onlySmallWindowsTuckTheSidebarAgainstTheRail() {
        let mini = IPadShellLayout(width: 1133, isAccessibilitySize: false, windowShortSide: 744)
        let elevenInch = IPadShellLayout(width: 820, isAccessibilitySize: false, windowShortSide: 820)
        let compact = IPadShellLayout(width: IPadShellLayout.compactWindowWidth - 1, isAccessibilitySize: false, windowShortSide: 744)
        let foldable = IPadShellLayout(width: 932, isAccessibilitySize: false, usesFoldableLayout: true, windowShortSide: 744)
        #expect(mini.sidebarLeadingInset == IPadShellLayout.railWidth)
        #expect(elevenInch.sidebarLeadingInset == elevenInch.railLeadingInset)
        #expect(elevenInch.sidebarPaneWidth == elevenInch.sidebarWidth)
        for layout in [mini, elevenInch, compact, foldable] {
            #expect(layout.sidebarLeadingInset >= 0)
            #expect(layout.sidebarLeadingInset + layout.sidebarPaneWidth == layout.railLeadingInset + layout.sidebarWidth)
        }
    }

    @Test func initialCompactWindowShowsTheWorkspaceList() {
        var state = IPadNavigationState()
        state.updateLayout(usesOverlay: true, usesCompactNavigation: true, showsWorkspaceList: true)
        #expect(state.section == .workspaces)
        #expect(state.isSidebarVisible)
        state.collapseSidebar()
        state.updateLayout(usesOverlay: true, usesCompactNavigation: true, showsWorkspaceList: true)
        #expect(!state.isSidebarVisible, "Ordinary width changes must not undo a manual drawer dismissal")
    }

    @Test(arguments: [false, true])
    func connectionSwitcherPreservesPersistentSidebar(expanded: Bool) {
        var state = IPadNavigationState()
        state.updateLayout(usesOverlay: false)
        if !expanded { state.collapseSidebar() }
        state.prepareForConnectionSwitcher(showingWorkspaceList: false)
        #expect(state.isSidebarVisible == expanded)
        #expect(state.isSidebarExpanded == expanded)
        #expect(state.section == .workspaces)
    }

    @Test func connectionSwitcherDismissesOnlyTheOverlaySidebar() {
        var state = IPadNavigationState()
        state.updateLayout(usesOverlay: true)
        state.revealSidebar()
        state.prepareForConnectionSwitcher(showingWorkspaceList: false)
        #expect(!state.isDrawerPresented)
        #expect(state.isSidebarExpanded)
        state.updateLayout(usesOverlay: true, usesCompactNavigation: true, showsWorkspaceList: true)
        state.prepareForConnectionSwitcher(showingWorkspaceList: true)
        #expect(state.isSidebarVisible)
    }

    @Test(arguments: [IPadSidebarSection.settings, .connections])
    func compactTransitionAndPairingCancellationKeepUtilitySidebarReachable(section: IPadSidebarSection) {
        var state = IPadNavigationState()
        state.showWorkspaceDetail()
        state.selectSection(section)
        state.updateLayout(usesOverlay: true, usesCompactNavigation: true)
        #expect(state.section == section)
        #expect(state.isSidebarVisible)
        state.presentPairing(.manual)
        #expect(!state.isSidebarVisible)
        state.cancelPairing()
        #expect(state.pairing == nil)
        #expect(state.section == section)
        #expect(state.isSidebarVisible)
        #expect(state.detail == .workspace)
    }

    @Test(arguments: [false, true])
    func compactTripsPreserveTheWideSidebarPreference(expanded: Bool) {
        var state = IPadNavigationState()
        state.showAssistantDetail()
        if !expanded { state.collapseSidebar() }
        state.updateLayout(usesOverlay: true, usesCompactNavigation: true)
        #expect(!state.isSidebarVisible)
        #expect(state.detail == .assistant)
        state.selectSection(.workspaces)
        #expect(state.isSidebarVisible)
        state.selectSection(.assistant)
        state.updateLayout(usesOverlay: false)
        #expect(state.isSidebarVisible == expanded)
        #expect(state.detail == .assistant)
        #expect(state.hasOpenedAssistant)
        #expect(!state.usesCompactNavigation)
    }
}

extension AppCoordinatorTests {
    @Test @MainActor func switchingShellsKeepsTheSelectedConversationAndRequest() {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [Self.makeWorkspace(id: "available")]
        let coordinator = AppCoordinator(workspaceStore: store, connection: FakeConnectionManager(), persistence: persistence)
        coordinator.onSelectAgent("agent", workspaceId: "available", agentName: "Agent")
        let route = coordinator.currentScreenDescription
        let request = coordinator.conversationRequestId
        for enabled in [true, false, true] {
            coordinator.updateShellPresentation(enabled)
            #expect(coordinator.usesIPadShell == enabled)
            #expect(coordinator.currentScreenDescription == route)
            #expect(coordinator.conversationRequestId == request)
            #expect(coordinator.selectedWorkspaceId == "available")
        }
    }

    @Test @MainActor func iPadWideLayoutSelectsWorkspaceAfterMeasurementAndLoading() {
        let store = WorkspaceStore(forTesting: true)
        let coordinator = AppCoordinator(workspaceStore: store, connection: FakeConnectionManager(), persistence: persistence)
        coordinator.usesIPadShell = true
        coordinator.currentScreen = .workspaceList
        coordinator.ensureIPadWorkspaceSelection()
        #expect(coordinator.selectedWorkspaceId == nil)
        coordinator.iPadNavigation.updateLayout(usesOverlay: false)
        coordinator.ensureIPadWorkspaceSelection()
        #expect(coordinator.selectedWorkspaceId == nil)
        store.workspaces = [
            Self.makeWorkspace(id: "archived", status: "archived"), Self.makeWorkspace(id: "deleted", status: "deleted"),
            Self.makeWorkspace(id: Workspace.chiefWorkspaceId), Self.makeWorkspace(id: "available")
        ]
        coordinator.ensureIPadWorkspaceSelection()
        #expect(coordinator.selectedWorkspaceId == "available")
        #expect(coordinator.currentScreenDescription == String(describing: AppScreen.workspaceDetail(workspaceId: "available")))
        coordinator.onSelectAgent("agent", workspaceId: "available", agentName: "Agent")
        let conversation = coordinator.currentScreenDescription
        coordinator.ensureIPadWorkspaceSelection()
        #expect(coordinator.currentScreenDescription == conversation)
        store.workspaces = [Self.makeWorkspace(id: "replacement")]
        coordinator.handleMissingWorkspace()
        #expect(coordinator.selectedWorkspaceId == "replacement")
        store.workspaces = []
        coordinator.handleMissingWorkspace()
        #expect(coordinator.selectedWorkspaceId == nil)
        #expect(coordinator.iPadNavigation.isSidebarVisible)
    }

    @Test @MainActor func iPadCompactBackRevealsListWithoutClearingSelection() {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [Self.makeWorkspace(id: "available")]
        let coordinator = AppCoordinator(workspaceStore: store, connection: FakeConnectionManager(), persistence: persistence)
        coordinator.usesIPadShell = true
        coordinator.currentScreen = .workspaceList
        coordinator.ensureIPadWorkspaceSelection()
        #expect(coordinator.selectedWorkspaceId == nil, "A window's initial width must be known before selecting")
        coordinator.iPadNavigation.updateLayout(usesOverlay: true, usesCompactNavigation: true, showsWorkspaceList: true)
        coordinator.ensureIPadWorkspaceSelection()
        #expect(coordinator.selectedWorkspaceId == nil)
        coordinator.onSelectWorkspace("available")
        let detail = coordinator.currentScreenDescription
        #expect(!coordinator.iPadNavigation.isSidebarVisible)
        coordinator.onBackToWorkspaceList()
        #expect(coordinator.iPadNavigation.isSidebarVisible)
        #expect(coordinator.selectedWorkspaceId == "available")
        #expect(coordinator.currentScreenDescription == detail)
        coordinator.iPadNavigation.updateLayout(usesOverlay: false)
        coordinator.ensureIPadWorkspaceSelection()
        #expect(coordinator.currentScreenDescription == detail)
    }
}
