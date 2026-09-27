import XCTest

nonisolated final class WorkspaceBrowserUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

    @MainActor
    func testCreatingBrowserValidatesAddressAndKeepsSessionAfterDismissal() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "--demo-browsers"]
        app.launch()
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
        workspace.tap()
        let actions = app.buttons["Workspace actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: Self.timeout))
        actions.tap()
        app.buttons["New browser"].tap()
        let address = app.textFields["Browser address"]
        XCTAssertTrue(address.waitForExistence(timeout: Self.timeout))
        address.tap()
        address.typeText("file:///etc/passwd")
        app.navigationBars.buttons["Open"].tap()
        XCTAssertTrue(address.exists)
        address.tap()
        let delete = String(repeating: XCUIKeyboardKey.delete.rawValue, count: "file:///etc/passwd".count)
        address.typeText(delete + "localhost:3000")
        app.navigationBars.buttons["Open"].tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: Self.timeout))
        done.tap()
        XCTAssertTrue(actions.waitForExistence(timeout: Self.timeout))
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", ":3000")).firstMatch
        if !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: Self.timeout))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "workspace-browsers"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        row.tap()
        XCTAssertTrue(done.waitForExistence(timeout: Self.timeout))
    }
}
