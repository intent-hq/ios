import XCTest

nonisolated final class MobileTerminalUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        continueAfterFailure = true
        try super.tearDownWithError()
    }

    @MainActor
    func testSwipeDeleteCanBeCancelledAndConfirmedFromWorkspace() {
        let app = launchWorkspaceWithTerminal()
        let terminal = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Terminal 1")).firstMatch
        XCTAssertTrue(terminal.appears(timeout: Self.timeout))
        terminal.swipeLeft()
        let delete = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.delete.")).firstMatch
        XCTAssertTrue(delete.appears(timeout: Self.timeout))
        XCTAssertTrue(delete.isHittable)
        capture(app, name: "mobile-terminal-swipe-delete")
        delete.tap()
        let confirmation = app.alerts["Delete terminal?"]
        XCTAssertTrue(confirmation.appears(timeout: Self.timeout))
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(terminal.exists)
        terminal.swipeRight()
        XCTAssertFalse(delete.isHittable)
        terminal.tap()
        XCTAssertTrue(app.staticTexts["mobile-terminal-title"].appears(timeout: Self.timeout))
        app.buttons["Back to workspace"].tap()
        terminal.swipeLeft()
        delete.tap()
        XCTAssertTrue(confirmation.appears(timeout: Self.timeout))
        confirmation.buttons["Delete terminal"].tap()
        XCTAssertTrue(terminal.disappears(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["Workspace actions"].exists)
    }

    @MainActor
    private func launchWorkspaceWithTerminal() -> XCUIApplication {
        let app = XCUIApplication.intent()
        app.launchArguments = ["--demo-data"]
        app.launch()
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(workspace.appears(timeout: Self.timeout))
        workspace.tap()
        let actions = app.buttons["Workspace actions"]
        XCTAssertTrue(actions.appears(timeout: Self.timeout))
        actions.tap()
        app.buttons["New terminal"].tap()
        XCTAssertTrue(app.staticTexts["mobile-terminal-title"].appears(timeout: Self.timeout))
        XCTAssertTrue(app.keyboards.firstMatch.appears(timeout: Self.timeout))
        app.buttons["Back to workspace"].tap()
        return app
    }

    @MainActor
    func testTerminalIsCreatedExplicitlyAndCanBeReopenedAndClosed() {
        let app = XCUIApplication.intent()
        app.launchArguments = ["--demo-data"]
        app.launch()
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(workspace.appears(timeout: Self.timeout))
        workspace.tap()
        let actions = app.buttons["Workspace actions"]
        XCTAssertTrue(actions.appears(timeout: Self.timeout))
        XCTAssertFalse(app.buttons["Terminal 1"].exists)
        actions.tap()
        app.buttons["New terminal"].tap()
        XCTAssertTrue(app.staticTexts["mobile-terminal-title"].appears(timeout: Self.timeout))
        app.buttons["Back to workspace"].tap()
        let terminal = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Terminal 1")).firstMatch
        XCTAssertTrue(terminal.appears(timeout: Self.timeout))
        capture(app, name: "mobile-terminal-workspace")
        terminal.tap()
        XCTAssertTrue(app.staticTexts["mobile-terminal-title"].appears(timeout: Self.timeout))
        checkKeyboardControls(app)
        app.buttons["Terminal actions"].tap()
        app.buttons["Close terminal"].tap()
        app.alerts.buttons["Close terminal"].tap()
        XCTAssertTrue(actions.appears(timeout: Self.timeout))
        XCTAssertFalse(terminal.exists)
    }

    @MainActor
    private func checkKeyboardControls(_ app: XCUIApplication) {
        let hideKeyboard = app.buttons["Hide keyboard"]
        XCTAssertTrue(hideKeyboard.appears(timeout: Self.timeout))
        XCTAssertTrue(app.keyboards.firstMatch.appears(timeout: Self.timeout))
        capture(app, name: "mobile-terminal-keyboard")
        app.buttons["Control"].tap()
        XCTAssertEqual(app.buttons["Control"].value as? String, "On")
        app.buttons["Control"].tap()
        XCTAssertEqual(app.buttons["Control"].value as? String, "Off")
        app.buttons["Arrow keys"].tap()
        XCTAssertTrue(app.buttons["Up Arrow"].exists)
        app.buttons["Up Arrow"].tap()
        capture(app, name: "mobile-terminal-arrows")
        app.buttons["Arrow keys"].tap()
        XCTAssertFalse(app.buttons["Up Arrow"].exists)
        hideKeyboard.tap()
        XCTAssertTrue(app.keyboards.firstMatch.disappears(timeout: Self.timeout))
        capture(app, name: "mobile-terminal-canvas")
        app.buttons["Show keyboard"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.appears(timeout: Self.timeout))
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
