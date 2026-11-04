import Foundation
@testable import Intent
import Testing

struct IPadToolPlacementTests {
    private let browser = IPadWorkspaceTool.browser(WorkspaceBrowser(
        id: "browser:preview", workspaceId: "workspace", title: "Preview", url: "http://localhost:3000", command: nil
    ))
    private let terminal = IPadWorkspaceTool.terminal(MobileTerminal(
        id: "terminal", workspaceId: "workspace", daemonBootId: "boot", name: "Terminal"
    ))

    @Test func placementRequiresMeasuredPersistentWorkspaceLayout() {
        var navigation = IPadNavigationState()
        var accepted = navigation.placeTool(browser)
        #expect(!accepted)
        navigation.updateLayout(usesOverlay: true)
        accepted = navigation.placeTool(browser)
        #expect(!accepted)
        navigation.updateLayout(usesOverlay: false)
        navigation.selectSection(.settings)
        accepted = navigation.placeTool(browser)
        #expect(!accepted)
        navigation.selectSection(.workspaces)
        navigation.presentPairing(.manual)
        accepted = navigation.placeTool(browser)
        #expect(!accepted)
        navigation.cancelPairing()
        accepted = navigation.placeTool(browser)
        #expect(accepted)
    }

    @Test func replacingToolAndSelectingChatKeepsSidebarVisible() {
        var navigation = IPadNavigationState()
        navigation.updateLayout(usesOverlay: false)
        navigation.collapseSidebar()
        let placedBrowser = navigation.placeTool(browser)
        #expect(placedBrowser)
        #expect(navigation.isSidebarVisible)
        navigation.showWorkspaceDetail()
        #expect(navigation.mainTool == browser)
        let placedTerminal = navigation.placeTool(terminal)
        #expect(placedTerminal)
        #expect(navigation.mainTool == terminal)
        navigation.closeTool()
        #expect(navigation.mainTool == nil)
    }

    @Test func narrowLayoutAndAssistantRestoreNormalNavigation() {
        var navigation = IPadNavigationState()
        navigation.updateLayout(usesOverlay: false)
        navigation.placeTool(browser)
        navigation.updateLayout(usesOverlay: true)
        #expect(navigation.mainTool == nil)
        navigation.updateLayout(usesOverlay: false)
        navigation.placeTool(terminal)
        navigation.showAssistantDetail()
        #expect(navigation.mainTool == nil)
        #expect(navigation.detail == .assistant)
    }

    @Test func dragPayloadRoundTripsWithoutToolContentAndIsWindowScoped() throws {
        let first = IPadNavigationState()
        let second = IPadNavigationState()
        #expect(first.toolDragWindowId != second.toolDragWindowId)
        let payload = IPadToolDrag(windowId: first.toolDragWindowId, toolId: browser.id, workspaceId: browser.workspaceId)
        let data = try JSONEncoder().encode(payload)
        let restored = try JSONDecoder().decode(IPadToolDrag.self, from: data)
        #expect(restored.windowId == first.toolDragWindowId)
        #expect(restored.toolId == browser.id)
        #expect(restored.workspaceId == browser.workspaceId)
    }
}
