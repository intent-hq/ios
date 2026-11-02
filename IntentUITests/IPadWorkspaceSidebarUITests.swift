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

    override func tearDownWithError() throws {
        continueAfterFailure = true
        try super.tearDownWithError()
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

            XCTAssertFalse(app.buttons["ipad.sidebar.collapse"].exists)
            app.buttons["Workspace actions"].firstMatch.tap()
            let collapse = app.buttons["ipad.sidebar.collapse"]
            XCTAssertTrue(collapse.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
            capture("ipad-workspace-sidebar-menu-\(appearance)")
            collapse.tap()
            let expand = app.buttons["ipad.sidebar.expand"]
            XCTAssertTrue(expand.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
            expand.tap()
            XCTAssertTrue(agent.wait(for: \.isSelected, toEqual: true, timeout: Self.timeout))

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

    /// #908: with no workspace to select, the detail pane shows a placeholder instead of a blank panel.
    @MainActor
    func testDetailPaneShowsPlaceholderWithoutSelectedWorkspaceInBothThemes() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad persistent sidebar")
        defer { XCUIDevice.shared.orientation = .portrait }
        for appearance in ["light", "dark"] {
            XCUIDevice.shared.orientation = .landscapeLeft
            let app = XCUIApplication()
            app.launchArguments = ["--demo-data", "--demo-empty-workspaces", "-appThemePreference", appearance]
            app.launch()
            let allowNotifications = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
            if allowNotifications.waitForExistence(timeout: 2) { allowNotifications.tap() }
            let placeholder = app.descendants(matching: .any)["workspace.detail.placeholder"]
            XCTAssertTrue(placeholder.waitForExistence(timeout: Self.timeout), "Landscape detail pane placeholder")
            XCTAssertTrue(placeholder.label.contains("Select a Workspace"), "VoiceOver reads the placeholder title")
            capture("ipad-empty-detail-landscape-\(appearance)")

            XCUIDevice.shared.orientation = .portrait
            XCTAssertTrue(placeholder.waitForExistence(timeout: Self.timeout), "Portrait detail pane placeholder")
            capture("ipad-empty-detail-portrait-\(appearance)")
            app.terminate()
        }
    }

    @MainActor
    func testGroupedAgentsStayListedAndNamedInTheSidebar() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad persistent sidebar")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "--demo-design-scenario=agent-groups", "-appThemePreference", "light"]
        app.launch()
        defer { app.terminate() }
        let workspace = app.staticTexts["Workspace agent design"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
        workspace.tap()
        let title = app.descendants(matching: .any)["conversation.header.title"]

        // Sections opened in the overview stay open in the sidebar, which then names the agent.
        let backgroundSection = app.buttons["workspace.agents.background"]
        XCTAssertTrue(backgroundSection.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        backgroundSection.tap()
        let background = app.buttons["workspace.agent.groups-background"]
        XCTAssertTrue(background.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        background.tap()
        XCTAssertTrue(background.wait(for: \.isSelected, toEqual: true, timeout: Self.timeout), "The background agent stays listed")
        XCTAssertTrue(title.waitForNonExistence(timeout: Self.timeout))
        capture("ipad-sidebar-background-agent")

        // Another tab hides the row, so the conversation names the agent itself.
        app.buttons["Context"].firstMatch.tap()
        XCTAssertTrue(title.waitForExistence(timeout: Self.timeout), "The title returns while the sidebar shows Context")
        capture("ipad-sidebar-context-beside-agent")
        app.buttons["Agents"].firstMatch.tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: Self.timeout))

        let back = app.buttons["conversation.back"]
        XCTAssertTrue(back.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        back.tap()
        let children = app.buttons["workspace.agents.children.groups-parent"]
        XCTAssertTrue(children.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        if children.value as? String != "Expanded" { children.tap() }
        let child = app.buttons["workspace.agent.groups-child"]
        XCTAssertTrue(child.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        child.tap()
        XCTAssertTrue(child.wait(for: \.isSelected, toEqual: true, timeout: Self.timeout), "The delegated agent stays listed")
        XCTAssertTrue(title.waitForNonExistence(timeout: Self.timeout))
        capture("ipad-sidebar-delegated-agent")
    }

    @MainActor
    func testConversationKeepsItsTitleWhenTheSidebarCannotListAgents() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad persistent sidebar")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "--demo-design-scenario=agent-list-unavailable", "-appThemePreference", "light"]
        app.launch()
        defer { app.terminate() }
        let workspace = app.staticTexts["Workspace agent design"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
        workspace.tap()
        let agent = app.buttons["workspace.agent.groups-parent"]
        XCTAssertTrue(agent.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        agent.tap()
        XCTAssertTrue(app.buttons["conversation.back"].waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(
            app.descendants(matching: .any)["conversation.header.title"].waitForExistence(timeout: Self.timeout),
            "A failed sidebar list leaves the conversation to name its agent"
        )
        capture("ipad-sidebar-list-failed")
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
        capture("ipad-overview-beside-sidebar")
        app.buttons["ipad.sidebar.collapse"].tap()
        let expand = app.buttons["ipad.sidebar.expand"]
        XCTAssertTrue(expand.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        capture("ipad-overview-sidebar-collapsed")
        expand.tap()
        XCTAssertTrue(app.collectionViews["workspaces.list"].wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))

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
    func testUnfoldedDuoDetailSwipesBetweenOverviewAndFirstAgent() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["INTENT_UITEST_UNFOLDED_DUO"] == "1",
            "Requires a user-configured unfolded Duo; this test never changes display mode"
        )
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "-appThemePreference", "light"]
        app.launch()
        defer { app.terminate() }
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(workspace.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        workspace.tap()
        app.buttons["Agents"].firstMatch.tap()
        let overview = app.scrollViews["workspace.detail.scroll"].firstMatch
        XCTAssertTrue(overview.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        overview.swipeLeft()
        let firstAgent = app.buttons[Self.firstAgent]
        XCTAssertTrue(firstAgent.wait(for: \.isSelected, toEqual: true, timeout: Self.timeout), "Left opens the first agent")
        capture("duo-swipe-first-agent")
        app.scrollViews["transcript.scrollView"].firstMatch.swipeRight()
        XCTAssertTrue(app.textViews["composer.textView"].waitForNonExistence(timeout: Self.timeout), "Right returns to the overview")
        XCTAssertTrue(firstAgent.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        XCTAssertFalse(firstAgent.isSelected)
        capture("duo-swipe-back-overview")
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
