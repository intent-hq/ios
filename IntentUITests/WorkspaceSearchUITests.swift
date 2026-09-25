import XCTest

nonisolated final class WorkspaceSearchUITests: XCTestCase {
    private enum Fixture {
        static let timeout: TimeInterval = 30
        static let dismissDuration: TimeInterval = 0.1
        static let dismissEnd: CGFloat = 0.9
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
        app.buttons["workspaces.viewMode.Repo"].tap()
        XCTAssertTrue(workspace.exists)
        app.buttons["workspaces.viewMode.Status"].tap()
        XCTAssertTrue(workspace.exists)
        field.tap()
        field.typeText("-no-match")
        XCTAssertTrue(workspace.waitForNonExistence(timeout: Fixture.timeout))
        app.buttons["workspaces.search.cancel"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Fixture.timeout))
    }

    @MainActor
    func testSearchSurvivesAssistantRoundTrip() {
        let app = launchWorkspaces()
        app.buttons["workspaces.search.open"].tap()
        let field = app.textFields["workspaces.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: Fixture.timeout))
        field.typeText("payment")
        app.buttons["assistant.open"].tap()
        let actions = app.buttons["assistant.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: Fixture.timeout))
        let sheetTop = app.navigationBars["Assistant"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
        sheetTop.press(forDuration: Fixture.dismissDuration, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: Fixture.dismissEnd)))
        XCTAssertTrue(actions.waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertTrue(field.waitForExistence(timeout: Fixture.timeout))
        XCTAssertEqual(field.value as? String, "payment")
        XCTAssertTrue(app.staticTexts[Fixture.workspaceTitle].firstMatch.exists)
        app.buttons["workspaces.search.cancel"].tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Workspace search beside view selector"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testFilterStaysPinnedAfterTitleScrollsAway() {
        let app = launchWorkspaces(arguments: ["--demo-long-workspace-list"])
        let list = app.scrollViews["workspaces.list"]
        let title = app.staticTexts["workspaces.title"]
        let search = app.buttons["workspaces.search.open"]
        let expandedPosition = search.frame.minY
        XCTAssertTrue(title.isHittable)
        let expanded = XCTAttachment(screenshot: app.screenshot())
        expanded.name = "Workspace header expanded"
        expanded.lifetime = .keepAlways
        add(expanded)
        for _ in 0 ..< Fixture.scrollAttempts where title.isHittable {
            list.swipeUp()
        }
        XCTAssertFalse(title.isHittable)
        XCTAssertFalse(app.buttons["Create workspace"].isHittable)
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
        app.launch()
        XCTAssertTrue(app.staticTexts[Fixture.workspaceTitle].firstMatch.waitForExistence(timeout: Fixture.timeout))
        return app
    }
}
