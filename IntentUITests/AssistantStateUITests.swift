import XCTest

nonisolated final class AssistantStateUITests: XCTestCase {
    private static let timeout: TimeInterval = 30

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        continueAfterFailure = true
        try super.tearDownWithError()
    }

    @MainActor
    func testLoadingFailureRetriesToEmptyAndStartsConversation() throws {
        for appearance in ["light", "dark"] {
            try verifyStateFlow(appearance: appearance, accessibility: false)
        }
    }

    @MainActor
    func testStateActionsRemainReachableWithAccessibilityText() throws {
        try verifyStateFlow(appearance: "dark", accessibility: true)
    }

    @MainActor
    private func verifyStateFlow(appearance: String, accessibility: Bool) throws {
        let trigger = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-list-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: trigger) }
        let app = XCUIApplication()
        app.launchArguments += [
            "--demo-data", "--demo-assistant-empty", "--demo-assistant-list-retry",
            "--demo-assistant-list-trigger-file=\(trigger.path)", "-appThemePreference", appearance
        ]
        if accessibility {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        defer { app.terminate() }
        let launcher = app.buttons["intent.menu.open"]
        XCTAssertTrue(launcher.waitForExistence(timeout: Self.timeout))
        launcher.tap()
        let assistant = app.buttons["intent.menu.assistant"]
        XCTAssertTrue(assistant.waitForExistence(timeout: Self.timeout))
        assistant.tap()
        let loading = app.staticTexts["Loading Assistant…"]
        XCTAssertTrue(loading.waitForExistence(timeout: Self.timeout))
        let newConversation = app.buttons["assistant.newConversation"]
        XCTAssertTrue(newConversation.exists)
        XCTAssertFalse(newConversation.isEnabled)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        let suffix = accessibility ? "accessibility" : appearance
        capture(app, name: "Assistant loading \(suffix)")

        try Data().write(to: trigger)
        let retry = app.buttons["Retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(retry.isHittable)
        XCTAssertFalse(newConversation.isEnabled)
        capture(app, name: "Assistant error \(suffix)")
        retry.tap()

        XCTAssertTrue(retry.waitForNonExistence(timeout: Self.timeout))
        let start = app.buttons["Start a Conversation"]
        XCTAssertTrue(start.waitForExistence(timeout: Self.timeout))
        if !start.isHittable { app.swipeUp() }
        XCTAssertTrue(start.isEnabled)
        XCTAssertTrue(start.isHittable)
        XCTAssertTrue(newConversation.isEnabled)
        XCTAssertTrue(app.buttons["assistant.actions"].isHittable)
        capture(app, name: "Assistant empty \(suffix)")
        start.tap()
        let composer = app.textViews["composer.textView"]
        XCTAssertTrue(composer.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(composer.isHittable)
        XCTAssertTrue(start.waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(newConversation.isHittable)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
