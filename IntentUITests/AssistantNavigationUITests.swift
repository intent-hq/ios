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
    func testAssistantAndWorkspaceSwitchingPreservesOpenWorkspace() {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data"]
        app.launch()

        let workspace = app.staticTexts[Fixture.workspaceTitle].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))
        workspace.tap()
        let context = app.buttons["Context"].firstMatch
        XCTAssertTrue(context.waitForExistence(timeout: Fixture.timeout))

        app.buttons["Assistant"].firstMatch.tap()
        let history = app.buttons["assistant.conversations"]
        XCTAssertTrue(history.waitForExistence(timeout: Fixture.timeout))
        let transcript = app.scrollViews["transcript.scrollView"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: Fixture.timeout))
        let assistantScreenshot = XCTAttachment(screenshot: app.screenshot())
        assistantScreenshot.name = "Global Assistant on iOS"
        assistantScreenshot.lifetime = .keepAlways
        add(assistantScreenshot)

        app.buttons["Workspaces"].firstMatch.tap()
        XCTAssertTrue(context.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.staticTexts["Test Stabilizer"].firstMatch.exists)

        app.buttons["Assistant"].firstMatch.tap()
        XCTAssertTrue(transcript.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(history.exists)
    }

    /// iPhone: the Workspaces/Assistant tab bar stays on the workspace
    /// overview but is hidden on a pushed conversation, so it never sits
    /// under the composer; popping back restores it.
    @MainActor
    func testTabBarHidesOnPushedWorkspaceConversation() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "compact-width behavior")
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data"]
        app.launch()

        let workspace = app.staticTexts[Fixture.workspaceTitle].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))
        workspace.tap()
        let agentRow = app.staticTexts["Test Stabilizer"].firstMatch
        XCTAssertTrue(agentRow.waitForExistence(timeout: Fixture.timeout))
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.exists, "the tab bar should show on the workspace overview")

        agentRow.tap()
        let transcript = app.scrollViews["transcript.scrollView"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(
            tabBar.waitForNonExistence(timeout: Fixture.timeout),
            "the tab bar must not sit under a pushed conversation's composer"
        )

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(agentRow.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(tabBar.waitForExistence(timeout: Fixture.timeout), "popping back must restore the tab bar")
    }

    @MainActor
    func testNewConversationIsAvailableWithoutScrollingHistory() {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-assistant-history"]
        app.launch()
        let assistantTab = app.buttons["Assistant"].firstMatch
        XCTAssertTrue(assistantTab.waitForExistence(timeout: Fixture.timeout))
        assistantTab.tap()

        let greeting = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "I can help you plan and follow up")
        ).firstMatch
        XCTAssertTrue(greeting.waitForExistence(timeout: Fixture.timeout))
        let newConversation = app.buttons["assistant.newConversation"]
        XCTAssertTrue(newConversation.isHittable)
        newConversation.tap()
        XCTAssertTrue(greeting.waitForNonExistence(timeout: Fixture.timeout))

        let history = app.buttons["assistant.conversations"]
        history.tap()
        let menuAction = app.buttons["New Conversation"].firstMatch
        XCTAssertTrue(menuAction.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(menuAction.isHittable)
        menuAction.tap()
        XCTAssertTrue(newConversation.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(newConversation.isHittable)
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
        let assistantTab = app.buttons["Assistant"].firstMatch
        XCTAssertTrue(assistantTab.waitForExistence(timeout: Fixture.timeout))
        assistantTab.tap()
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
