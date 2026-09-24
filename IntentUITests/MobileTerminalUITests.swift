import XCTest

nonisolated final class MobileTerminalUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

    @MainActor
    func testTerminalIsCreatedExplicitlyAndCanBeReopenedAndClosed() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data"]
        app.launch()
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
        workspace.tap()
        let actions = app.buttons["Workspace actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: Self.timeout))
        XCTAssertFalse(app.buttons["Terminal 1"].exists)
        actions.tap()
        app.buttons["New terminal"].tap()
        XCTAssertTrue(app.navigationBars["Terminal 1"].waitForExistence(timeout: Self.timeout))
        app.buttons["Done"].tap()
        let terminal = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Terminal 1")).firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: Self.timeout))
        terminal.tap()
        XCTAssertTrue(app.navigationBars["Terminal 1"].waitForExistence(timeout: Self.timeout))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Mobile workspace terminal"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Terminal actions"].tap()
        app.buttons["Close terminal"].tap()
        app.alerts.buttons["Close terminal"].tap()
        XCTAssertTrue(actions.waitForExistence(timeout: Self.timeout))
        XCTAssertFalse(terminal.exists)
    }
}
