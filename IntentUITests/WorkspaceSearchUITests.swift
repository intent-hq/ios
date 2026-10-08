import XCTest

nonisolated final class WorkspaceSearchUITests: XCTestCase {
    private enum Fixture {
        static let timeout: TimeInterval = 30
        static let scrollAttempts = 4
        static let workspaceTitle = "Deflake payment integration tests"
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        continueAfterFailure = true
        try super.tearDownWithError()
    }

    @MainActor
    func testWorkspaceControlsHaveSeparateTargetsAndSelectEveryMode() {
        let app = launchWorkspaces()
        let modes = ["Recent", "Repo", "Status"]
        let controls = modes.map { app.buttons["workspaces.viewMode.\($0)"] }
            + [app.buttons["workspaces.search.open"]]
        for control in controls {
            XCTAssertTrue(control.isHittable)
            XCTAssertGreaterThanOrEqual(control.frame.width, 44 - 0.001)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44 - 0.001)
        }
        for (left, right) in zip(controls, controls.dropFirst()) {
            XCTAssertFalse(left.frame.intersects(right.frame), "Each control must own a separate target")
        }
        for mode in ["Repo", "Status", "Recent"] {
            let selected = app.buttons["workspaces.viewMode.\(mode)"]
            selected.tap()
            XCTAssertTrue(selected.wait(for: \.isSelected, toEqual: true, timeout: Fixture.timeout))
            for other in modes where other != mode {
                XCTAssertFalse(app.buttons["workspaces.viewMode.\(other)"].isSelected)
            }
        }
        app.buttons["workspaces.search.open"].tap()
        XCTAssertTrue(app.textFields["workspaces.search.field"].waitForExistence(timeout: Fixture.timeout))
    }

    @MainActor
    func testSearchFiltersAndClearAndCancelRestoreWorkspaces() {
        let app = launchWorkspaces()
        app.buttons["workspaces.search.open"].tap()
        let field = app.textFields["workspaces.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: Fixture.timeout))
        field.typeText("no-matching-workspace")
        let workspace = app.staticTexts[Fixture.workspaceTitle].firstMatch
        XCTAssertTrue(workspace.waitForNonExistence(timeout: Fixture.timeout))
        app.buttons["workspaces.search.clear"].tap()
        XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))

        field.typeText("payment")
        XCTAssertTrue(workspace.exists)
        field.typeText("-no-match")
        XCTAssertTrue(workspace.waitForNonExistence(timeout: Fixture.timeout))
        app.buttons["workspaces.search.cancel"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Fixture.timeout))
    }

    @MainActor
    func testHidingSidebarDuringSearchRestoresUnfilteredWorkspaces() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad sidebar behavior")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchWorkspaces()
        let otherWorkspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(otherWorkspace.exists)
        app.buttons["workspaces.search.open"].tap()
        let field = app.textFields["workspaces.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: Fixture.timeout))
        field.typeText("payment")
        XCTAssertTrue(otherWorkspace.waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertFalse(app.buttons["intent.menu.open"].exists)

        app.buttons["Hide Sidebar"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.buttons["intent.menu.open"].waitForExistence(timeout: Fixture.timeout))
        app.buttons["Show Sidebar"].tap()
        XCTAssertTrue(otherWorkspace.waitForExistence(timeout: Fixture.timeout))
        app.buttons["workspaces.search.open"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: Fixture.timeout))
        XCTAssertEqual(field.value as? String, "Search workspaces")
    }

    @MainActor
    func testSearchAboveKeyboardHidesAssistantUntilClosed() {
        let app = launchWorkspaces()
        XCTAssertTrue(app.buttons["intent.menu.open"].exists)
        app.buttons["workspaces.search.open"].tap()
        let field = app.textFields["workspaces.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: Fixture.timeout))
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: Fixture.timeout))
        XCTAssertLessThanOrEqual(field.frame.maxY, keyboard.frame.minY)
        XCTAssertGreaterThan(field.frame.minY, app.frame.midY)
        XCTAssertFalse(app.buttons["intent.menu.open"].exists)
        XCTAssertFalse(app.buttons["workspaces.viewMode.Recent"].exists)
        field.typeText("payment")
        XCTAssertTrue(app.staticTexts[Fixture.workspaceTitle].firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Workspace search above keyboard without Assistant launcher"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        field.typeText("\n")
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertTrue(field.exists)
        XCTAssertFalse(app.buttons["intent.menu.open"].exists)
        app.buttons["workspaces.search.cancel"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.buttons["intent.menu.open"].exists)
        XCTAssertTrue(app.buttons["workspaces.viewMode.Recent"].isHittable)
        app.buttons["workspaces.search.open"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: Fixture.timeout))
        XCTAssertEqual(field.value as? String, "Search workspaces")
    }

    @MainActor
    func testSearchFiltersGroupedWorkspaces() {
        let app = launchWorkspaces()
        for mode in ["Repo", "Status"] {
            app.buttons["workspaces.viewMode.\(mode)"].tap()
            app.buttons["workspaces.search.open"].tap()
            let field = app.textFields["workspaces.search.field"]
            XCTAssertTrue(field.waitForExistence(timeout: Fixture.timeout))
            field.typeText("payment")
            XCTAssertTrue(app.staticTexts[Fixture.workspaceTitle].firstMatch.exists)
            field.typeText("-no-match")
            XCTAssertTrue(app.staticTexts[Fixture.workspaceTitle].firstMatch.waitForNonExistence(timeout: Fixture.timeout))
            app.buttons["workspaces.search.cancel"].tap()
            XCTAssertTrue(app.buttons["workspaces.viewMode.\(mode)"].isSelected)
        }
    }

    @MainActor
    func testFilterStaysPinnedAfterTitleScrollsAway() {
        let app = launchWorkspaces(arguments: [
            "--demo-long-workspace-list", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"
        ])
        let list = app.scrollViews["workspaces.list"]
        let title = app.staticTexts["workspaces.title"]
        let search = app.buttons["workspaces.search.open"]
        let expandedPosition = search.frame.minY
        XCTAssertTrue(title.isHittable)
        let expanded = XCTAttachment(screenshot: app.screenshot())
        expanded.name = "Workspace header expanded"
        expanded.lifetime = .keepAlways
        add(expanded)
        let menu = app.buttons["workspaces.menu"]
        // Figma: the menu is centered on the 29pt cap-trimmed title, then 64pt to the filters.
        XCTAssertEqual(search.frame.minY - menu.frame.midY, 78.5, accuracy: 2)
        XCTAssertTrue(menu.isHittable)
        // Accessibility frame conversion can round a 44pt target just below 44.
        XCTAssertGreaterThanOrEqual(menu.frame.width, 44 - 0.001)
        XCTAssertGreaterThanOrEqual(menu.frame.height, 44 - 0.001)
        for _ in 0 ..< Fixture.scrollAttempts where title.isHittable {
            list.swipeUp()
        }
        XCTAssertFalse(title.isHittable)
        XCTAssertTrue(search.isHittable)
        XCTAssertLessThan(search.frame.minY, expandedPosition)
        XCTAssertTrue(app.buttons["workspaces.viewMode.Repo"].isHittable)
        let collapsed = XCTAttachment(screenshot: app.screenshot())
        collapsed.name = "Workspace filters pinned after scrolling"
        collapsed.lifetime = .keepAlways
        add(collapsed)
        search.tap()
        let field = app.textFields["workspaces.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: Fixture.timeout))
        field.typeText("payment")
        XCTAssertTrue(app.staticTexts[Fixture.workspaceTitle].firstMatch.waitForExistence(timeout: Fixture.timeout))
        app.buttons["workspaces.search.cancel"].tap()
    }

    @MainActor
    private func launchWorkspaces(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data"] + arguments
        app.launchArguments += ["-appThemePreference", ProcessInfo.processInfo.environment["INTENT_UITEST_APPEARANCE"] ?? "light"]
        app.launch()
        XCTAssertTrue(app.staticTexts[Fixture.workspaceTitle].firstMatch.waitForExistence(timeout: Fixture.timeout))
        let allowNotifications = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allowNotifications.waitForExistence(timeout: 2) { allowNotifications.tap() }
        return app
    }
}
