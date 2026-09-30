import XCTest

nonisolated final class WorkspaceTransferUITests: XCTestCase {
    private static let timeout: TimeInterval = 30

    @MainActor
    func testWorkspaceMenuOpensTransferFormAndDismissesWithoutLeavingWorkspace() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data"]
        if let appearance = ProcessInfo.processInfo.environment["INTENT_UITEST_APPEARANCE"] {
            app.launchArguments += ["-appThemePreference", appearance]
        }
        app.launch()
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
        workspace.tap()
        let actions = app.buttons["Workspace actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: Self.timeout))
        actions.tap()
        let transfer = app.buttons["workspace.transfer"]
        XCTAssertTrue(transfer.waitForExistence(timeout: Self.timeout))
        transfer.tap()

        let destination = app.buttons["workspace-transfer.destination"]
        XCTAssertTrue(destination.waitForExistence(timeout: Self.timeout))
        let submit = app.buttons["workspace-transfer.submit"]
        XCTAssertTrue(submit.exists)
        XCTAssertFalse(submit.isEnabled, "A transfer requires an explicit destination.")
        let archive = app.switches["workspace-transfer.archive-source"]
        XCTAssertEqual(archive.value as? String, "0")
        archive.tap()
        XCTAssertEqual(archive.value as? String, "1")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "ios-workspace-transfer-sheet"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["connection-sheet.close"].tap()
        XCTAssertTrue(destination.waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(actions.exists)
        actions.tap()
        transfer.tap()
        XCTAssertTrue(destination.waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(archive.value as? String, "0", "Reopening starts a fresh form.")
    }
}
