import Foundation
@testable import Intent
import Testing

@MainActor
struct IPadCompactNavigationTests {
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
