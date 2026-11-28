import XCTest

nonisolated final class AppStoreScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        continueAfterFailure = true
        try super.tearDownWithError()
    }

    @MainActor
    private func configureOrientation() {
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
    }

    @MainActor
    private func dismissNotificationPrompt() {
        let allowNotifications = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allowNotifications.appears(timeout: 2) {
            allowNotifications.tap()
            XCTAssertTrue(allowNotifications.disappears(timeout: 5))
        }
    }

    @MainActor
    func testCaptureDemoModeScreenshots() {
        configureOrientation()
        let app = XCUIApplication.intent()
        setupSnapshot(app)
        app.launchArguments += ["--demo-data"]
        app.launch()
        dismissNotificationPrompt()

        let workspaceRow = app.staticTexts["Add usage analytics dashboard"].firstMatch
        if !workspaceRow.appears(timeout: 30) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(workspaceRow.appears(timeout: 15))
        }
        snapshot("01-workspace-list")

        workspaceRow.tap()
        let agentRow = app.staticTexts["Dashboard Implementor"].firstMatch
        XCTAssertTrue(agentRow.appears(timeout: 15))
        snapshot("02-workspace-detail")

        agentRow.tap()
        let conversationMessage = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS[c] %@", "more than 90 days"))
            .firstMatch
        XCTAssertTrue(conversationMessage.appears(timeout: 15))
        snapshot("03-agent-conversation")

        let customBackButton = app.buttons["conversation.back"]
        let nativeBackButton = app.navigationBars["Dashboard Implementor"].buttons.element(boundBy: 0)
        let agentsBackButton = customBackButton.exists ? customBackButton : nativeBackButton
        XCTAssertTrue(agentsBackButton.appears(timeout: 15))
        agentsBackButton.tap()
        XCTAssertTrue(agentRow.appears(timeout: 15))

        app.buttons["Context"].firstMatch.tap()
        let specRow = app.staticTexts["Spec"].firstMatch
        XCTAssertTrue(specRow.appears(timeout: 15))
        specRow.tap()
        XCTAssertTrue(app.navigationBars["Spec"].appears(timeout: 15))
        let loadedNote = app.buttons["Open task CSV export with streamed download"]
        XCTAssertTrue(loadedNote.appears(timeout: 15))
        snapshot("04-note-tasks")
    }

    @MainActor
    func testCapturePairingScreenshot() {
        configureOrientation()
        let app = XCUIApplication.intent()
        setupSnapshot(app)
        app.launch()
        dismissNotificationPrompt()

        let scanOption = app.staticTexts["Scan QR Code"].firstMatch
        XCTAssertTrue(scanOption.appears(timeout: 30))
        snapshot("05-pairing")
    }
}
