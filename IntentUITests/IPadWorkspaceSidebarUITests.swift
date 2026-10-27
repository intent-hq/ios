import XCTest

nonisolated final class IPadWorkspaceSidebarUITests: XCTestCase {
    private static let timeout: TimeInterval = 30
    private static let agent = "workspace.agent.demo-agent-implementor"
    private static let note = "workspace.note.demo-note-spec"
    private static let firstAgent = "workspace.agent.demo-agent-reviewer"

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
            app.buttons["Agents"].firstMatch.tap()
            let agent = app.buttons[Self.agent]
            XCTAssertTrue(agent.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
            capture("ipad-workspace-overview-\(appearance)")

            agent.tap()
            XCTAssertTrue(app.textViews["composer.textView"].waitForExistence(timeout: Self.timeout))
            XCTAssertTrue(agent.wait(for: \.isSelected, toEqual: true, timeout: Self.timeout), "The open agent is marked in the sidebar")
            capture("ipad-workspace-sidebar-agent-\(appearance)")

            app.buttons["Context"].firstMatch.tap()
            let note = app.buttons[Self.note]
            XCTAssertTrue(note.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
            note.tap()
            XCTAssertTrue(note.wait(for: \.isSelected, toEqual: true, timeout: Self.timeout), "A note keeps its workspace in the sidebar")
            capture("ipad-workspace-sidebar-note-\(appearance)")

            XCUIDevice.shared.orientation = .portrait
            XCTAssertTrue(app.buttons["ipad.rail.workspaces"].waitForExistence(timeout: Self.timeout))
            capture("ipad-workspace-sidebar-portrait-\(appearance)")
            XCUIDevice.shared.orientation = .landscapeLeft
            let back = app.buttons["Back to workspace"]
            XCTAssertTrue(back.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))

            back.tap()
            XCTAssertTrue(back.waitForNonExistence(timeout: Self.timeout))
            XCTAssertTrue(app.collectionViews["workspaces.list"].wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
            XCTAssertTrue(note.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout), "The overview returns to the detail pane")
            XCTAssertFalse(note.isSelected)
            capture("ipad-workspace-sidebar-back-\(appearance)")
            app.buttons["Agents"].firstMatch.tap()
            app.terminate()
        }
    }

    @MainActor
    func testPaneSwipesMoveBetweenOverviewAndFirstAgent() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad main pane swipes")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "-appThemePreference", "light"]
        app.launch()
        defer { app.terminate() }
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
        workspace.tap()
        app.buttons["Agents"].firstMatch.tap()
        let overview = app.scrollViews["workspace.detail.scroll"].firstMatch
        XCTAssertTrue(overview.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))

        overview.swipeLeft()
        let firstAgent = app.buttons[Self.firstAgent]
        XCTAssertTrue(firstAgent.wait(for: \.isSelected, toEqual: true, timeout: Self.timeout), "Left opens the first agent")
        XCTAssertTrue(app.textViews["composer.textView"].waitForExistence(timeout: Self.timeout))
        capture("ipad-swipe-first-agent")

        app.scrollViews["transcript.scrollView"].firstMatch.swipeRight()
        XCTAssertTrue(app.collectionViews["workspaces.list"].wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        XCTAssertTrue(firstAgent.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout), "Right returns to the overview")
        XCTAssertFalse(firstAgent.isSelected)
        capture("ipad-swipe-back-overview")
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
