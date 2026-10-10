import XCTest

nonisolated final class ConversationActionsUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

    @MainActor
    func testHistoryNoticeAndActionCancellationPreserveConversation() {
        let app = launch(scenario: "history", appearance: "light")
        let transcript = app.scrollViews["transcript.scrollView"]
        XCTAssertTrue(transcript.waitForExistence(timeout: Self.timeout))
        XCTAssertFalse(app.staticTexts["transcript.historyNotice"].exists)
        capture(app, named: "Conversation-History-Light")

        openActions(app)
        XCTAssertTrue(app.buttons["conversation.actions.model"].isHittable)
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
        capture(app, named: "Agent-Delete-Confirmation-Light")
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
        let composer = app.textViews["composer.textView"]
        composer.tap()
        composer.typeText("Continue with this draft")
        openActions(app)
        app.buttons["conversation.actions.model"].tap()
        let picker = app.navigationBars["Select Model"]
        XCTAssertTrue(picker.waitForExistence(timeout: Self.timeout))
        let selectedModel = app.buttons["conversation.model.default-model"]
        XCTAssertTrue(selectedModel.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(selectedModel.isSelected)
        capture(app, named: "Agent-Model-Picker-Light")
        app.buttons["conversation.model.named-model"].tap()
        XCTAssertTrue(picker.waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(transcript.exists)
        XCTAssertEqual(composer.value as? String, "Continue with this draft")
        openActions(app)
        XCTAssertTrue(app.staticTexts["Model: Named Model"].waitForExistence(timeout: Self.timeout))
    }

    @MainActor
    func testLargeTextModelPickerWorksAfterSending() {
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
        if UIDevice.current.userInterfaceIdiom == .pad {
            let close = app.buttons["ipad.focus.close"]
            XCTAssertTrue(close.waitForExistence(timeout: Self.timeout))
            XCTAssertFalse(app.buttons["conversation.actions.open"].exists)
            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: Self.timeout))
            XCTAssertEqual(composer.value as? String, "")
            XCTAssertTrue(app.buttons["composer.stop"].exists, "Closing focus must retain the streaming conversation")
        }
        openActions(app)
        XCTAssertTrue(model.isHittable)
        XCTAssertTrue(app.buttons["conversation.actions.rename"].exists)
        model.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: Self.timeout))
        let namedModel = app.buttons["conversation.model.named-model"]
        XCTAssertTrue(namedModel.waitForExistence(timeout: Self.timeout))
        capture(app, named: "Agent-Model-Picker-Dark-LargeText")
        namedModel.tap()
        XCTAssertTrue(picker.waitForNonExistence(timeout: Self.timeout))
        openActions(app)
        XCTAssertTrue(app.staticTexts["Model: Named Model"].waitForExistence(timeout: Self.timeout))
        model.tap()
        XCTAssertTrue(namedModel.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(namedModel.isSelected)
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
    private func capture(_: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
