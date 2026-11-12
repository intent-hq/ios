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

    @Test func compactWidthsAlwaysUseTheOverlay() {
        for width in stride(from: CGFloat(1), to: IPadShellLayout.compactWindowWidth, by: 1) {
            for accessibility in [false, true] {
                for foldable in [false, true] {
                    for leadingBar in [false, true] {
                        let layout = IPadShellLayout(
                            width: width,
                            isAccessibilitySize: accessibility,
                            usesFoldableLayout: foldable,
                            usesLeadingVerticalBar: leadingBar
                        )
                        #expect(layout.usesSidebarOverlay, "Compact width \(width) must overlay")
                    }
                }
            }
        }
    }

    /// Only 12 of the 32 combinations of the five former layout flags happen:
    /// before measurement and at split width there is no drawer, and compact implies overlay.
    @Test func layoutModeReachesOnlyTheInventoriedCombinations() {
        typealias Operation = (inout IPadNavigationState) -> Void
        let operations: [Operation] = [
            { $0.revealSidebar() },
            { $0.collapseSidebar() },
            { $0.showWorkspaceDetail() },
            { $0.selectSection(.settings) },
            { $0.presentPairing(.manual) },
            { $0.cancelPairing() },
            { $0.prepareForConnectionSwitcher(showingWorkspaceList: false) },
            { $0.updateLayout(usesOverlay: false) },
            { $0.updateLayout(usesOverlay: true) },
            { $0.updateLayout(usesOverlay: true, usesCompactNavigation: true, showsWorkspaceList: true) }
        ]
        func flags(_ state: IPadNavigationState) -> [Bool] {
            [
                state.isSidebarExpanded, state.isDrawerPresented, state.usesSidebarOverlay,
                state.usesCompactNavigation, state.hasMeasuredLayout
            ]
        }
        var seen: Set<[Bool]> = []
        func visit(_ state: IPadNavigationState, depth: Int) {
            seen.insert(flags(state))
            guard depth > 0 else { return }
            for operation in operations {
                var next = state
                operation(&next)
                visit(next, depth: depth - 1)
            }
        }
        visit(IPadNavigationState(), depth: 4)
        var expected: Set<[Bool]> = []
        for expanded in [false, true] {
            expected.insert([expanded, false, false, false, false])
            expected.insert([expanded, false, false, false, true])
            for drawer in [false, true] {
                expected.insert([expanded, drawer, true, false, true])
                expected.insert([expanded, drawer, true, true, true])
            }
        }
        #expect(seen == expected)
    }

    @Test func layoutModeTransitions() {
        var state = IPadNavigationState()
        #expect(state.layoutMode == .unmeasured)
        #expect(!state.canPlaceTool)
        state.collapseSidebar()
        state.updateLayout(usesOverlay: false)
        #expect(state.layoutMode == .split)
        #expect(!state.isSidebarVisible, "The first split measurement keeps a choice made before it")
        #expect(state.canPlaceTool)
        state.revealSidebar()
        let browser = IPadWorkspaceTool.browser(WorkspaceBrowser(
            id: "browser:preview", workspaceId: "workspace", title: "Preview", url: "http://localhost:3000", command: nil
        ))
        let placed = state.placeTool(browser)
        #expect(placed)
        state.updateLayout(usesOverlay: true)
        #expect(state.layoutMode == .overlay(drawerOpen: false))
        #expect(state.mainTool == nil)
        state.revealSidebar()
        state.updateLayout(usesOverlay: true)
        #expect(state.layoutMode == .overlay(drawerOpen: true), "Remeasuring the same width keeps the drawer open")
        state.updateLayout(usesOverlay: true, usesCompactNavigation: true)
        #expect(state.layoutMode == .compact(drawerOpen: false))
        state.revealSidebar()
        state.showWorkspaceDetail()
        #expect(state.layoutMode == .compact(drawerOpen: false), "Selecting a detail closes the drawer")
        state.updateLayout(usesOverlay: false)
        #expect(state.layoutMode == .split)
        #expect(state.isSidebarExpanded)
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
        coordinator.applyIPadAutoSelection()
        #expect(coordinator.selectedWorkspaceId == nil)
        coordinator.iPadNavigation.updateLayout(usesOverlay: false)
        coordinator.applyIPadAutoSelection()
        #expect(coordinator.selectedWorkspaceId == nil)
        store.workspaces = [
            Self.makeWorkspace(id: "archived", status: "archived"), Self.makeWorkspace(id: "deleted", status: "deleted"),
            Self.makeWorkspace(id: Workspace.chiefWorkspaceId), Self.makeWorkspace(id: "available")
        ]
        coordinator.applyIPadAutoSelection()
        #expect(coordinator.selectedWorkspaceId == "available")
        #expect(coordinator.currentScreenDescription == String(describing: AppScreen.workspaceDetail(workspaceId: "available")))
        coordinator.onSelectAgent("agent", workspaceId: "available", agentName: "Agent")
        let conversation = coordinator.currentScreenDescription
        coordinator.applyIPadAutoSelection()
        #expect(coordinator.currentScreenDescription == conversation)
        store.workspaces = [Self.makeWorkspace(id: "replacement")]
        coordinator.handleMissingWorkspace()
        coordinator.applyIPadAutoSelection()
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
        coordinator.applyIPadAutoSelection()
        #expect(coordinator.selectedWorkspaceId == nil, "A window's initial width must be known before selecting")
        coordinator.iPadNavigation.updateLayout(usesOverlay: true, usesCompactNavigation: true, showsWorkspaceList: true)
        coordinator.applyIPadAutoSelection()
        #expect(coordinator.selectedWorkspaceId == nil)
        coordinator.onSelectWorkspace("available")
        let detail = coordinator.currentScreenDescription
        #expect(!coordinator.iPadNavigation.isSidebarVisible)
        coordinator.onBackToWorkspaceList()
        #expect(coordinator.iPadNavigation.isSidebarVisible)
        #expect(coordinator.selectedWorkspaceId == "available")
        #expect(coordinator.currentScreenDescription == detail)
        coordinator.iPadNavigation.updateLayout(usesOverlay: false)
        coordinator.applyIPadAutoSelection()
        #expect(coordinator.currentScreenDescription == detail)
    }
}
