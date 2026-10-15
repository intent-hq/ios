import XCTest

nonisolated final class WorkspaceSearchUITests: XCTestCase {
    private enum Fixture {
        static let timeout: TimeInterval = 30
        static let scrollAttempts = 4
        static let focusPanelWidth: CGFloat = 624
        static let focusContentInset: CGFloat = 32
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
            let overlap = left.frame.intersection(right.frame)
            // iOS segments share edges; tolerate subpixel accessibility frame rounding.
            XCTAssertFalse(overlap.width > 0.001 && overlap.height > 0.001, "Each control must own a separate target")
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
        captureSearchState(name: "Workspace Intent menu button")
        app.buttons["workspaces.search.open"].tap()
        let field = app.textFields["workspaces.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: Fixture.timeout))
        field.typeText("no-matching-workspace")
        let workspace = app.staticTexts[Fixture.workspaceTitle].firstMatch
        XCTAssertTrue(workspace.waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.descendants(matching: .any)["workspaces.search.empty"].waitForExistence(timeout: Fixture.timeout))
        captureSearchState(name: "Empty workspace search results")
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
    func testIPadSearchSurvivesCollapseAndSectionChanges() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad focused search")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        for appearance in ["light", "dark"] {
            let app = launchWorkspaces(appearance: appearance)
            let heading = app.staticTexts["workspace.title.heading"]
            XCTAssertTrue(heading.waitForExistence(timeout: Fixture.timeout))
            let selectedTitle = heading.label
            app.buttons["workspaces.search.open"].tap()
            let field = app.textFields["workspaces.search.field"]
            XCTAssertTrue(field.waitForExistence(timeout: Fixture.timeout))
            field.typeText("payment")
            XCTAssertFalse(app.staticTexts["Add usage analytics dashboard"].firstMatch.exists)
            XCTAssertFalse(app.buttons["intent.menu.open"].exists)
            XCTAssertFalse(app.buttons["ipad.rail.workspaces"].exists)
            XCTAssertFalse(app.buttons["ipad.sidebar.collapse"].exists)
            XCTAssertFalse(heading.isHittable)
            let cancel = app.buttons["workspaces.search.cancel"]
            XCTAssertTrue(cancel.isHittable)
            let panel = app.otherElements["ipad.sidebar.panel"]
            XCTAssertEqual(panel.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 2)
            XCTAssertEqual(panel.frame.width, Fixture.focusPanelWidth, accuracy: 2)
            XCTAssertEqual(panel.frame.maxX - cancel.frame.maxX, Fixture.focusContentInset, accuracy: 2)
            XCTAssertLessThanOrEqual(field.frame.maxY, app.keyboards.firstMatch.frame.minY)
            captureSearchState(name: "iPad focused search \(appearance)")
            verifySearchWithoutKeyboardAndRotation(in: app, field: field, appearance: appearance)
            cancel.tap()
            XCTAssertTrue(field.waitForNonExistence(timeout: Fixture.timeout))
            XCTAssertTrue(heading.wait(for: \.isHittable, toEqual: true, timeout: Fixture.timeout))
            XCTAssertEqual(heading.label, selectedTitle)
            captureSearchState(name: "iPad search restored \(appearance)")
            app.buttons["ipad.sidebar.collapse"].tap()
            app.buttons["ipad.sidebar.expand"].tap()
            app.buttons["ipad.rail.settings"].tap()
            app.buttons["ipad.rail.workspaces"].tap()
            XCTAssertEqual(heading.label, selectedTitle)
            XCTAssertTrue(app.buttons["workspaces.search.open"].isHittable)
            app.terminate()
        }
    }

    @MainActor
    private func verifySearchWithoutKeyboardAndRotation(in app: XCUIApplication, field: XCUIElement, appearance: String) {
        field.typeText("\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.buttons["workspaces.search.cancel"].isHittable)
        XCTAssertFalse(app.buttons["ipad.rail.workspaces"].exists)
        XCTAssertEqual(field.value as? String, "payment")
        captureSearchState(name: "iPad focused search keyboard hidden \(appearance)")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(field.wait(for: \.isHittable, toEqual: true, timeout: Fixture.timeout))
        XCTAssertEqual(field.value as? String, "payment")
        XCTAssertTrue(app.buttons["workspaces.search.cancel"].isHittable)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(field.wait(for: \.isHittable, toEqual: true, timeout: Fixture.timeout))
    }

    @MainActor
    func testIPadFocusedSearchSelectionOpensTheWorkspace() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad focused search selection")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchWorkspaces()
        app.buttons["workspaces.search.open"].tap()
        let field = app.textFields["workspaces.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: Fixture.timeout))
        field.typeText("payment")
        app.buttons["workspace.row.demo-ws-flaky-tests"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: Fixture.timeout))
        let heading = app.staticTexts["workspace.title.heading"]
        XCTAssertTrue(heading.wait(for: \.label, toEqual: Fixture.workspaceTitle, timeout: Fixture.timeout))
        XCTAssertTrue(app.buttons["ipad.rail.workspaces"].isHittable)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Fixture.timeout))
    }

    @MainActor
    private func captureSearchState(name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testSearchAboveKeyboardHidesAssistantUntilClosed() {
        let app = launchWorkspaces()
        let navigation = UIDevice.current.userInterfaceIdiom == .pad ? "ipad.rail.workspaces" : "intent.menu.open"
        XCTAssertTrue(app.buttons[navigation].exists)
        app.buttons["workspaces.search.open"].tap()
        let field = app.textFields["workspaces.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: Fixture.timeout))
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: Fixture.timeout))
        XCTAssertLessThanOrEqual(field.frame.maxY, keyboard.frame.minY)
        if UIDevice.current.userInterfaceIdiom != .pad {
            XCTAssertGreaterThan(field.frame.minY, app.frame.midY)
        }
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
        XCTAssertTrue(app.buttons[navigation].exists)
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
    private func launchWorkspaces(arguments: [String] = [], appearance: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data"] + arguments
        app.launchArguments += ["-appThemePreference", appearance ?? ProcessInfo.processInfo.environment["INTENT_UITEST_APPEARANCE"] ?? "light"]
        app.launch()
        XCTAssertTrue(app.staticTexts[Fixture.workspaceTitle].firstMatch.waitForExistence(timeout: Fixture.timeout))
        let allowNotifications = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allowNotifications.waitForExistence(timeout: 2) { allowNotifications.tap() }
        return app
    }
}
