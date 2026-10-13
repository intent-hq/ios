import XCTest

nonisolated final class WorkspaceTitleEditingUITests: XCTestCase {
    private static let workspaceTitle = "Add usage analytics dashboard"
    private static let timeout: TimeInterval = 30

    @MainActor
    func testDoubleTapShowsKeyboardAndDoneSavesTheTitle() {
        let app = openWorkspace()
        let heading = app.staticTexts["workspace.title.heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: Self.timeout))
        heading.doubleTap()
        let field = app.textFields["workspace.title.field"]
        let done = app.buttons["workspace.title.done"]
        XCTAssertTrue(field.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Self.timeout))
        field.typeText(" edited")
        XCTAssertTrue(done.isHittable)
        XCTAssertGreaterThan(done.frame.midX, app.frame.midX)
        XCTAssertLessThanOrEqual(done.frame.maxY, app.keyboards.firstMatch.frame.minY)
        capture(app, name: "Workspace title editing with keyboard and floating Done")

        done.tap()

        XCTAssertTrue(field.waitForNonExistence(timeout: Self.timeout))
        XCTAssertEqual(heading.label, Self.workspaceTitle + " edited")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Self.timeout))
        if app.buttons["workspaceDetail.back"].exists {
            app.buttons["workspaceDetail.back"].tap()
        } else {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(app.staticTexts[Self.workspaceTitle + " edited"].firstMatch.waitForExistence(timeout: Self.timeout))
    }

    @MainActor
    func testTitleDraftSurvivesScrollingOffscreenAndBack() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-design-scenario=agent-groups-large"]
        app.launch()
        let workspace = app.staticTexts["Workspace agent design"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
        workspace.tap()
        let heading = app.staticTexts["workspace.title.heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: Self.timeout))
        heading.doubleTap()
        let field = app.textFields["workspace.title.field"]
        XCTAssertTrue(field.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Self.timeout))
        field.typeText(" edited")
        let draft = "Workspace agent design edited"
        XCTAssertEqual(field.value as? String, draft)
        let scroll = app.scrollViews["workspace.detail.scroll"]
        XCTAssertTrue(scroll.exists)
        scroll.swipeUp()
        scroll.swipeUp()
        XCTAssertFalse(field.isHittable)
        for _ in 0..<6 where !field.isHittable { scroll.swipeDown() }
        XCTAssertTrue(field.isHittable)
        XCTAssertEqual(field.value as? String, draft)
        field.tap()
        field.typeText(" again")
        XCTAssertEqual(field.value as? String, draft + " again")
        app.buttons["workspace.title.cancel"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: Self.timeout))
        XCTAssertEqual(heading.label, "Workspace agent design")
    }

    @MainActor
    func testFailedSaveKeepsTheDraftAndCancelDiscardsIt() {
        let app = openWorkspace(failing: true)
        let heading = app.staticTexts["workspace.title.heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: Self.timeout))
        heading.doubleTap()
        let field = app.textFields["workspace.title.field"]
        XCTAssertTrue(field.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Self.timeout))
        field.typeText(" edited")
        app.buttons["workspace.title.done"].tap()

        XCTAssertTrue(app.staticTexts["workspace.title.error"].waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(field.value as? String, Self.workspaceTitle + " edited")
        app.buttons["workspace.title.cancel"].tap()

        XCTAssertTrue(field.waitForNonExistence(timeout: Self.timeout))
        XCTAssertEqual(heading.label, Self.workspaceTitle)
    }

    @MainActor
    private func openWorkspace(failing: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-workspace-actions"]
        if failing { app.launchArguments.append("--demo-workspace-action-error") }
        app.launch()
        let workspace = app.staticTexts[Self.workspaceTitle].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
        workspace.tap()
        return app
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
