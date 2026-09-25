import XCTest

nonisolated final class AssistantNavigationUITests: XCTestCase {
    private enum Fixture {
        static let timeout: TimeInterval = 30
        static let workspaceTitle = "Deflake payment integration tests"
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        continueAfterFailure = true
        try super.tearDownWithError()
    }

    @MainActor
    func testAssistantButtonOpensAndReturnsToWorkspaces() {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data"]
        app.launch()

        let workspace = app.staticTexts[Fixture.workspaceTitle].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))
        let launcher = app.buttons["assistant.open"]
        XCTAssertTrue(launcher.isHittable)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        let workspaceScreenshot = XCTAttachment(screenshot: app.screenshot())
        workspaceScreenshot.name = "Workspace list with Assistant button"
        workspaceScreenshot.lifetime = .keepAlways
        add(workspaceScreenshot)
        launcher.tap()
        let actions = app.buttons["assistant.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.tabBars.firstMatch.waitForNonExistence(timeout: Fixture.timeout))
        let transcript = app.scrollViews["transcript.scrollView"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: Fixture.timeout))
        let assistantScreenshot = XCTAttachment(screenshot: app.screenshot())
        assistantScreenshot.name = "Global Assistant on iOS"
        assistantScreenshot.lifetime = .keepAlways
        add(assistantScreenshot)

        app.buttons["assistant.back"].tap()
        XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(launcher.isHittable)
        XCTAssertFalse(app.tabBars.firstMatch.exists)

        launcher.tap()
        XCTAssertTrue(transcript.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(actions.exists)
    }

    @MainActor
    func testAssistantButtonStaysOnWorkspaceList() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "compact-width behavior")
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data"]
        app.launch()

        let workspace = app.staticTexts[Fixture.workspaceTitle].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))
        let launcher = app.buttons["assistant.open"]
        XCTAssertTrue(launcher.isHittable)
        workspace.tap()
        let agentRow = app.staticTexts["Test Stabilizer"].firstMatch
        XCTAssertTrue(agentRow.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(launcher.waitForNonExistence(timeout: Fixture.timeout))

        agentRow.tap()
        let transcript = app.scrollViews["transcript.scrollView"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: Fixture.timeout))
        XCTAssertFalse(launcher.exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(agentRow.waitForExistence(timeout: Fixture.timeout))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(launcher.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(launcher.isHittable)
    }

    @MainActor
    func testNewConversationIsAvailableWithoutScrollingHistory() {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-assistant-history"]
        app.launch()
        let launcher = app.buttons["assistant.open"]
        XCTAssertTrue(launcher.waitForExistence(timeout: Fixture.timeout))
        launcher.tap()

        let greeting = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "I can help you plan and follow up")
        ).firstMatch
        XCTAssertTrue(greeting.waitForExistence(timeout: Fixture.timeout))
        let newConversation = app.buttons["assistant.newConversation"]
        XCTAssertTrue(newConversation.isHittable)
        newConversation.tap()
        XCTAssertTrue(greeting.waitForNonExistence(timeout: Fixture.timeout))

        app.buttons["assistant.actions"].tap()
        let history = app.buttons["assistant.conversations"]
        XCTAssertTrue(history.waitForExistence(timeout: Fixture.timeout))
        history.tap()
        let menuAction = app.buttons["New Conversation"].firstMatch
        XCTAssertTrue(menuAction.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(menuAction.isHittable)
        menuAction.tap()
        XCTAssertTrue(newConversation.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(newConversation.isHittable)
    }

    @MainActor
    func testConversationHistoryInActionsSwitchesReplies() {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-assistant-history"]
        app.launch()
        let launcher = app.buttons["assistant.open"]
        XCTAssertTrue(launcher.waitForExistence(timeout: Fixture.timeout))
        launcher.tap()
        let greeting = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "I can help you plan and follow up")
        ).firstMatch
        XCTAssertTrue(greeting.waitForExistence(timeout: Fixture.timeout))
        let actions = app.buttons["assistant.actions"]
        actions.tap()
        app.buttons["assistant.conversations"].tap()
        app.buttons["Earlier conversation 0"].firstMatch.tap()
        XCTAssertTrue(greeting.waitForNonExistence(timeout: Fixture.timeout))
        actions.tap()
        app.buttons["assistant.conversations"].tap()
        app.buttons["Assistant"].firstMatch.tap()
        XCTAssertTrue(greeting.waitForExistence(timeout: Fixture.timeout))
    }

    @MainActor
    func testCompletedSuggestedPromptsReplaceStreamingMarkup() throws {
        try verifyPromptCompletion(splitAcrossBlocks: false)
    }

    @MainActor
    func testCompletedSuggestedPromptsAcrossBlocksReplaceStreamingMarkup() throws {
        try verifyPromptCompletion(splitAcrossBlocks: true)
    }

    @MainActor
    private func verifyPromptCompletion(splitAcrossBlocks: Bool) throws {
        let trigger = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-prompts-\(UUID().uuidString).trigger")
        defer { try? FileManager.default.removeItem(at: trigger) }
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-assistant-prompts-trigger-file=\(trigger.path)"]
        if splitAcrossBlocks { app.launchArguments.append("--demo-assistant-prompts-split") }
        app.launch()
        let launcher = app.buttons["assistant.open"]
        XCTAssertTrue(launcher.waitForExistence(timeout: Fixture.timeout))
        launcher.tap()
        let transcript = app.scrollViews["transcript.scrollView"].firstMatch
        let rawMarkup = transcript.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "suggested-prompts")
        ).firstMatch
        XCTAssertTrue(rawMarkup.waitForExistence(timeout: Fixture.timeout), app.debugDescription)
        try Data().write(to: trigger)
        let firstPrompt = app.buttons["transcript.suggestedPrompt.0"]
        XCTAssertTrue(firstPrompt.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(firstPrompt.isHittable)
        XCTAssertTrue(app.buttons["transcript.suggestedPrompt.1"].isHittable)
        XCTAssertTrue(rawMarkup.waitForNonExistence(timeout: Fixture.timeout), app.debugDescription)
        let greeting = transcript.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Hey bro — what’s on your mind?")
        ).firstMatch
        XCTAssertTrue(greeting.exists)
        XCTAssertFalse(greeting.label.contains("Show me what needs my attention."))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Assistant prompts after streaming completes"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
