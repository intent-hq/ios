import XCTest

nonisolated final class ConversationActionsUITests: XCTestCase {
    private static let timeout: TimeInterval = 15
    private static let maximumSwipes = 8

    @MainActor
    func testHistoryNoticeAndActionCancellationPreserveConversation() {
        let app = launch(scenario: "history", appearance: "light")
        let transcript = app.scrollViews["transcript.scrollView"]
        let history = app.staticTexts["transcript.historyNotice"]
        for _ in 0..<Self.maximumSwipes where !history.isHittable { transcript.swipeDown() }
        XCTAssertTrue(history.isHittable)
        XCTAssertTrue(history.label.contains("3 of 103 messages"))
        capture(app, named: "History-Notice-Light")

        openActions(app)
        XCTAssertFalse(app.buttons["conversation.actions.model"].exists)
        capture(app, named: "Agent-Actions-Light")
        app.buttons["conversation.actions.rename"].tap()
        let rename = app.alerts["Rename Agent"]
        XCTAssertTrue(rename.waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(rename.textFields.firstMatch.value as? String, "Continue Spec Writer")
        rename.buttons["Cancel"].tap()
        XCTAssertTrue(rename.waitForNonExistence(timeout: Self.timeout))

        openActions(app)
        app.buttons["conversation.actions.delete"].tap()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: Self.timeout))
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else {
            transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.8)).tap()
        }
        XCTAssertTrue(delete.waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["conversation.actions.open"].isHittable)

        openActions(app)
        transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.8)).tap()
        XCTAssertTrue(app.buttons["conversation.actions.rename"].waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(app.textViews["composer.textView"].exists)
    }

    @MainActor
    func testLargeTextModelPickerReturnsAndSendingRemovesModelAction() {
        let app = launch(scenario: "empty", appearance: "dark", largeText: true)
        openActions(app)
        let model = app.buttons["conversation.actions.model"]
        XCTAssertTrue(model.isHittable)
        capture(app, named: "Agent-Actions-Dark-LargeText")
        model.tap()
        let picker = app.navigationBars["Select Model"]
        XCTAssertTrue(picker.waitForExistence(timeout: Self.timeout))
        picker.buttons["Cancel"].tap()
        XCTAssertTrue(picker.waitForNonExistence(timeout: Self.timeout))

        let composer = app.textViews["composer.textView"]
        composer.tap()
        composer.typeText("Keep the current model")
        app.buttons["composer.send"].tap()
        XCTAssertTrue(app.buttons["composer.stop"].waitForExistence(timeout: Self.timeout))
        openActions(app)
        XCTAssertFalse(model.exists, "Model changes are only available before the first message")
        XCTAssertTrue(app.buttons["conversation.actions.rename"].exists)
    }

    @MainActor
    private func launch(scenario: String, appearance: String, largeText: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += [
            "--demo-data", "--demo-design-scenario=\(scenario)", "-appThemePreference", appearance,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        let workspace = app.staticTexts["Workspace agent design"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
        workspace.tap()
        let agent = app.buttons["workspace.agent.demo-agent-design"]
        XCTAssertTrue(agent.waitForExistence(timeout: Self.timeout))
        agent.tap()
        XCTAssertTrue(app.textViews["composer.textView"].waitForExistence(timeout: Self.timeout))
        return app
    }

    @MainActor
    private func openActions(_ app: XCUIApplication) {
        let button = app.buttons["conversation.actions.open"]
        XCTAssertTrue(button.waitForExistence(timeout: Self.timeout))
        button.tap()
        XCTAssertTrue(app.buttons["conversation.actions.rename"].waitForExistence(timeout: Self.timeout), app.debugDescription)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
