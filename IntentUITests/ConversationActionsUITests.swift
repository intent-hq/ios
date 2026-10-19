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
        closeTypingFocus(in: app)
        openActions(app)
        app.buttons["conversation.actions.model"].tap()
        let picker = app.navigationBars["Model Settings"]
        XCTAssertTrue(picker.waitForExistence(timeout: Self.timeout))
        assertField("Default Model", identifier: "creation.modelPicker", in: app)
        capture(app, named: "Agent-Model-Picker-Light")
        choose("Named Model", identifier: "creation.modelPicker", in: app)
        app.buttons["conversation.model.save"].tap()
        XCTAssertTrue(picker.waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(transcript.exists)
        XCTAssertEqual(composer.value as? String, "Continue with this draft")
        openActions(app)
        assertNamedModelInMenu(app)
        capture(app, named: "Agent-Actions-Updated-Light")
    }

    @MainActor
    func testLargeTextModelPickerWorksAfterSending() {
        let app = launch(scenario: "empty", appearance: "dark", largeText: true)
        openActions(app)
        let model = app.buttons["conversation.actions.model"]
        XCTAssertTrue(model.isHittable)
        capture(app, named: "Agent-Actions-Dark-LargeText")
        model.tap()
        let picker = app.navigationBars["Model Settings"]
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
        assertField("Default Model", identifier: "creation.modelPicker", in: app)
        capture(app, named: "Agent-Model-Picker-Dark-LargeText")
        choose("Named Model", identifier: "creation.modelPicker", in: app)
        app.buttons["conversation.model.save"].tap()
        XCTAssertTrue(picker.waitForNonExistence(timeout: Self.timeout))
        openActions(app)
        assertNamedModelInMenu(app)
        model.tap()
        assertField("Named Model", identifier: "creation.modelPicker", in: app)
        capture(app, named: "Agent-Model-Picker-Selected-Dark-LargeText")
    }

    @MainActor
    func testAssistantModelPickerUsesInheritedProviderAndPreservesDraft() {
        for appearance in ["light", "dark"] {
            let app = launchAssistant(appearance: appearance)
            let composer = app.textViews["composer.textView"]
            composer.tap()
            composer.typeText("Keep this Assistant draft")
            closeTypingFocus(in: app)
            app.buttons["assistant.actions"].tap()
            app.buttons["conversation.actions.model"].tap()
            assertField("Codex", identifier: "creation.providerPicker", in: app)
            assertField("Default Model", identifier: "creation.modelPicker", in: app)
            capture(app, named: "Assistant-Model-Picker-\(appearance)")
            choose("Auggie", identifier: "creation.providerPicker", in: app)
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Self.timeout))
            assertField("Provider default", identifier: "creation.modelPicker", in: app)
            choose("Named Model", identifier: "creation.modelPicker", in: app)
            choose("high", identifier: "creation.reasoningPicker", in: app)
            capture(app, named: "Assistant-Model-Settings-selected-\(appearance)")
            app.buttons["conversation.model.save"].tap()
            XCTAssertTrue(app.navigationBars["Model Settings"].waitForNonExistence(timeout: Self.timeout))
            XCTAssertEqual(composer.value as? String, "Keep this Assistant draft")
            XCTAssertTrue(app.scrollViews["transcript.scrollView"].exists)
            app.buttons["assistant.actions"].tap()
            assertNamedModelInMenu(app)
            app.buttons["conversation.actions.model"].tap()
            assertSavedAssistantSettings(app)
            choose("Codex", identifier: "creation.providerPicker", in: app)
            app.navigationBars["Model Settings"].buttons["Cancel"].tap()
            XCTAssertTrue(app.navigationBars["Model Settings"].waitForNonExistence(timeout: Self.timeout))
            app.buttons["assistant.actions"].tap()
            app.buttons["conversation.actions.model"].tap()
            assertSavedAssistantSettings(app)
            app.terminate()
        }
    }

    @MainActor
    func testEmptyAssistantModelPickerOffersRetryAndCancel() {
        let app = launchAssistant(appearance: "light", arguments: ["--demo-model-catalog-empty", "--demo-assistant-reasoning-high"])
        app.buttons["assistant.actions"].tap()
        app.buttons["conversation.actions.model"].tap()
        let retry = app.buttons["Retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: Self.timeout))
        retry.tap()
        XCTAssertTrue(retry.waitForExistence(timeout: Self.timeout))
        capture(app, named: "Assistant-Model-Picker-Empty")
        assertField("high", identifier: "creation.reasoningPicker", in: app)
        choose("Auto", identifier: "creation.reasoningPicker", in: app)
        app.buttons["conversation.model.save"].tap()
        XCTAssertTrue(app.navigationBars["Model Settings"].waitForNonExistence(timeout: Self.timeout))
        app.buttons["assistant.actions"].tap()
        app.buttons["conversation.actions.model"].tap()
        assertField("Auto", identifier: "creation.reasoningPicker", in: app)
        assertField("Codex", identifier: "creation.providerPicker", in: app)
        assertField("default-model", identifier: "creation.modelPicker", in: app)
        app.navigationBars["Model Settings"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Model Settings"].waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(app.textViews["composer.textView"].exists)
    }

    @MainActor
    private func assertSavedAssistantSettings(_ app: XCUIApplication) {
        assertField("Auggie", identifier: "creation.providerPicker", in: app)
        assertField("Named Model", identifier: "creation.modelPicker", in: app)
        assertField("high", identifier: "creation.reasoningPicker", in: app)
    }

    @MainActor
    private func choose(_ value: String, identifier: String, in app: XCUIApplication) {
        let field = app.buttons[identifier]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: Self.timeout), .completed)
        if !field.isHittable { app.scrollViews["conversation.model.form"].swipeUp() }
        XCTAssertTrue(field.isHittable)
        field.tap()
        let choice = app.buttons[value]
        XCTAssertTrue(choice.waitForExistence(timeout: Self.timeout))
        choice.tap()
        assertField(value, identifier: identifier, in: app)
    }

    @MainActor
    private func assertField(_ value: String, identifier: String, in app: XCUIApplication) {
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: app.buttons[identifier])
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: Self.timeout), .completed)
    }

    @MainActor
    private func launchAssistant(appearance: String, arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "-appThemePreference", appearance, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + arguments
        app.launch()
        if UIDevice.current.userInterfaceIdiom == .pad {
            selectIPadSection("assistant", in: app)
            let thread = app.buttons["assistant.thread.demo-agent-assistant"]
            XCTAssertTrue(thread.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
            thread.tap()
        } else {
            let launcher = app.buttons["intent.menu.open"]
            XCTAssertTrue(launcher.waitForExistence(timeout: Self.timeout))
            launcher.tap()
            let assistant = app.buttons["intent.menu.assistant"]
            XCTAssertTrue(assistant.waitForExistence(timeout: Self.timeout))
            assistant.tap()
        }
        XCTAssertTrue(app.buttons["assistant.actions"].waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.textViews["composer.textView"].waitForExistence(timeout: Self.timeout))
        return app
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
        if UIDevice.current.userInterfaceIdiom == .pad { selectIPadSection("workspaces", in: app) }
        let workspace = app.buttons["workspace.row.demo-ws-agent-design"]
        XCTAssertTrue(workspace.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        workspace.tap()
        let agent = app.buttons["workspace.agent.demo-agent-design"]
        XCTAssertTrue(agent.waitForExistence(timeout: Self.timeout))
        agent.tap()
        XCTAssertTrue(app.textViews["composer.textView"].waitForExistence(timeout: Self.timeout))
        return app
    }

    @MainActor
    private func selectIPadSection(_ section: String, in app: XCUIApplication) {
        let destination = app.buttons["ipad.rail.\(section)"]
        XCTAssertTrue(destination.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        destination.tap()
        XCTAssertTrue(destination.wait(for: \.isSelected, toEqual: true, timeout: Self.timeout))
    }

    @MainActor
    private func closeTypingFocus(in app: XCUIApplication) {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        let close = app.buttons["ipad.focus.close"]
        XCTAssertTrue(close.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Self.timeout))
    }

    @MainActor
    private func assertNamedModelInMenu(_ app: XCUIApplication) {
        let modelButton = app.buttons.matching(identifier: "conversation.actions.model")
            .matching(NSPredicate(format: "label == %@", "Named Model")).firstMatch
        XCTAssertTrue(modelButton.waitForExistence(timeout: Self.timeout), app.debugDescription)
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
