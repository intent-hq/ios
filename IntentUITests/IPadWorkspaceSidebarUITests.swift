import XCTest

nonisolated final class IPadWorkspaceSidebarUITests: XCTestCase {
    private static let timeout: TimeInterval = 30
    private static let agent = "workspace.agent.demo-agent-implementor"
    private static let note = "workspace.note.demo-note-spec"

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    @MainActor
    func testOpenAgentAndNoteMoveTheWorkspaceIntoTheSidebarInBothThemes() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad persistent sidebar")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["--demo-data", "-appThemePreference", appearance]
            app.launch()
            let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
            XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
            workspace.tap()
            let agent = app.buttons[Self.agent]
            XCTAssertTrue(agent.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
            capture("ipad-workspace-overview-\(appearance)")

            agent.tap()
            let back = app.buttons["workspaceSidebar.back"]
            XCTAssertTrue(back.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
            XCTAssertTrue(app.textViews["composer.textView"].waitForExistence(timeout: Self.timeout))
            XCTAssertTrue(app.buttons[Self.agent].isSelected, "The open agent is marked in the sidebar")
            XCTAssertFalse(app.collectionViews["workspaces.list"].isHittable)
            capture("ipad-workspace-sidebar-agent-\(appearance)")

            app.buttons["Context"].firstMatch.tap()
            let note = app.buttons[Self.note]
            XCTAssertTrue(note.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
            note.tap()
            XCTAssertTrue(note.wait(for: \.isSelected, toEqual: true, timeout: Self.timeout))
            XCTAssertTrue(back.isHittable, "A note keeps its workspace in the sidebar")
            capture("ipad-workspace-sidebar-note-\(appearance)")

            XCUIDevice.shared.orientation = .portrait
            XCTAssertTrue(app.buttons["ipad.rail.workspaces"].waitForExistence(timeout: Self.timeout))
            capture("ipad-workspace-sidebar-portrait-\(appearance)")
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(back.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))

            back.tap()
            let list = app.collectionViews["workspaces.list"]
            XCTAssertTrue(list.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
            XCTAssertTrue(back.waitForNonExistence(timeout: Self.timeout))
            XCTAssertTrue(app.buttons["Back to workspace"].exists, "Back keeps the open note in the detail pane")
            capture("ipad-workspace-sidebar-back-\(appearance)")
            app.terminate()
        }
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
