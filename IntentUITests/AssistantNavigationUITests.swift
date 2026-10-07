import XCTest

nonisolated final class AssistantNavigationUITests: XCTestCase {
    private enum Fixture {
        static let timeout: TimeInterval = 30
        static let dismissDuration: TimeInterval = 0.1
        static let dismissEnd: CGFloat = 0.9
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
        app.launchArguments += ["-appThemePreference", ProcessInfo.processInfo.environment["INTENT_UITEST_APPEARANCE"] ?? "light"]
        app.launch()

        showWorkspaceList(in: app)
        let isCompact = !app.navigationBars["Workspaces"].exists
        let workspace = app.staticTexts[Fixture.workspaceTitle].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))
        let launcher = app.buttons["intent.menu.open"]
        XCTAssertTrue(launcher.isHittable)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        let workspaceScreenshot = XCTAttachment(screenshot: app.screenshot())
        workspaceScreenshot.name = "Workspace list with Assistant button"
        workspaceScreenshot.lifetime = .keepAlways
        add(workspaceScreenshot)
        launcher.tap()
        let assistantTile = app.buttons["intent.menu.assistant"]
        XCTAssertTrue(assistantTile.waitForExistence(timeout: Fixture.timeout))
        assistantTile.tap()
        let actions = app.buttons["assistant.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.tabBars.firstMatch.waitForNonExistence(timeout: Fixture.timeout))
        let transcript = app.scrollViews["transcript.scrollView"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: Fixture.timeout))
        let header = isCompact
            ? app.otherElements["assistant.header"].firstMatch
            : app.navigationBars["Assistant"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.buttons["assistant.newConversation"].isHittable)
        XCTAssertFalse(app.buttons["conversation.back"].exists)
        if isCompact {
            XCTAssertFalse(app.navigationBars["Assistant"].exists)
            XCTAssertEqual(header.staticTexts.matching(NSPredicate(format: "label == %@", "Assistant")).count, 1)
        }
        let assistantScreenshot = XCTAttachment(screenshot: app.screenshot())
        assistantScreenshot.name = "Global Assistant on iOS"
        assistantScreenshot.lifetime = .keepAlways
        add(assistantScreenshot)

        let sheetTop = header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
        sheetTop.press(forDuration: Fixture.dismissDuration, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: Fixture.dismissEnd)))
        XCTAssertTrue(actions.waitForNonExistence(timeout: Fixture.timeout))
        XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(launcher.isHittable)
        XCTAssertFalse(app.tabBars.firstMatch.exists)

        launcher.tap()
        XCTAssertTrue(assistantTile.waitForExistence(timeout: Fixture.timeout))
        assistantTile.tap()
        XCTAssertTrue(transcript.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(actions.exists)
    }

    @MainActor
    func testAssistantComposerKeepsHeaderActionsReachable() {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments += ["--demo-data", "-appThemePreference", appearance]
            app.launch()
            let launcher = app.buttons["intent.menu.open"]
            XCTAssertTrue(launcher.waitForExistence(timeout: Fixture.timeout))
            launcher.tap()
            let assistantTile = app.buttons["intent.menu.assistant"]
            XCTAssertTrue(assistantTile.waitForExistence(timeout: Fixture.timeout))
            assistantTile.tap()

            let composer = app.textViews["composer.textView"]
            XCTAssertTrue(composer.waitForExistence(timeout: Fixture.timeout))
            composer.tap()
            let message = "Help me plan my next workspace."
            composer.typeText(message)
            let send = app.buttons["composer.send"]
            XCTAssertTrue(send.isHittable)
            send.tap()
            let transcript = app.scrollViews["transcript.scrollView"].firstMatch
            XCTAssertTrue(transcript.staticTexts[message].waitForExistence(timeout: Fixture.timeout))
            XCTAssertEqual(composer.value as? String, "")
            XCTAssertTrue(app.buttons["assistant.newConversation"].isHittable)
            XCTAssertTrue(app.buttons["assistant.actions"].isHittable)

            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Assistant chat sent message \(appearance)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.terminate()
        }
    }

    @MainActor
    func testAssistantButtonStaysOnWorkspaceList() {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data"]
        app.launch()

        showWorkspaceList(in: app)
        let isCompact = !app.navigationBars["Workspaces"].exists
        let workspace = app.staticTexts[Fixture.workspaceTitle].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))
        let launcher = app.buttons["intent.menu.open"]
        XCTAssertTrue(launcher.isHittable)
        workspace.tap()
        let hideSidebar = app.navigationBars["Workspaces"].buttons["Hide Sidebar"]
        if hideSidebar.exists { hideSidebar.tap() }
        let agentRow = app.staticTexts["Test Stabilizer"].firstMatch
        XCTAssertTrue(agentRow.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(agentRow.isHittable, app.debugDescription)
        if isCompact {
            XCTAssertTrue(launcher.waitForNonExistence(timeout: Fixture.timeout))
        } else {
            XCTAssertTrue(launcher.isHittable)
        }

        agentRow.tap()
        let transcript = app.scrollViews["transcript.scrollView"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: Fixture.timeout))
        if isCompact {
            XCTAssertFalse(launcher.exists)
        } else {
            XCTAssertTrue(launcher.isHittable)
        }
        XCTAssertFalse(app.tabBars.firstMatch.exists)

        let conversationBack = isCompact
            ? app.buttons["conversation.back"]
            : app.navigationBars["Test Stabilizer"].buttons["BackButton"]
        XCTAssertTrue(conversationBack.waitForExistence(timeout: Fixture.timeout), app.debugDescription)
        conversationBack.tap()
        XCTAssertTrue(agentRow.waitForExistence(timeout: Fixture.timeout))
        let workspaceBack = isCompact
            ? app.buttons["workspaceDetail.back"]
            : app.navigationBars.buttons["Back to workspaces"]
        XCTAssertTrue(workspaceBack.waitForExistence(timeout: Fixture.timeout), app.debugDescription)
        workspaceBack.tap()
        showWorkspaceList(in: app)
        XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(launcher.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(launcher.isHittable)
    }

    @MainActor
    private func showWorkspaceList(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["intent.menu.open"].waitForExistence(timeout: Fixture.timeout))
        let sidebar = app.navigationBars.buttons["Show Sidebar"]
        if sidebar.exists { sidebar.tap() }
        XCTAssertTrue(app.staticTexts[Fixture.workspaceTitle].firstMatch.waitForExistence(timeout: Fixture.timeout), app.debugDescription)
    }

    @MainActor
    func testNewConversationIsAvailableWithoutScrollingHistory() {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-assistant-history"]
        app.launch()
        let launcher = app.buttons["intent.menu.open"]
        XCTAssertTrue(launcher.waitForExistence(timeout: Fixture.timeout))
        launcher.tap()
        let assistantTile = app.buttons["intent.menu.assistant"]
        XCTAssertTrue(assistantTile.waitForExistence(timeout: Fixture.timeout))
        assistantTile.tap()

        let greeting = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "I can help you plan and follow up")
        ).firstMatch
        XCTAssertTrue(greeting.waitForExistence(timeout: Fixture.timeout))
        let newConversation = app.buttons["assistant.newConversation"]
        XCTAssertTrue(newConversation.isHittable)
        let newConversationLabel = newConversation.label
        newConversation.tap()
        XCTAssertTrue(greeting.waitForNonExistence(timeout: Fixture.timeout))

        app.buttons["assistant.actions"].tap()
        let history = app.buttons["assistant.conversations"]
        XCTAssertTrue(history.waitForExistence(timeout: Fixture.timeout))
        history.tap()
        // Native submenus on iOS 27 omit SwiftUI identifiers. Match the app's
        // localized toolbar label inside the menu, never the toolbar itself.
        let menuAction = app.collectionViews.buttons[newConversationLabel]
        XCTAssertTrue(menuAction.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(menuAction.isHittable, app.debugDescription)
        menuAction.tap()
        XCTAssertTrue(newConversation.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(newConversation.isHittable)
    }

    @MainActor
    func testConversationHistoryInActionsSwitchesReplies() {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-assistant-history"]
        app.launch()
        let launcher = app.buttons["intent.menu.open"]
        XCTAssertTrue(launcher.waitForExistence(timeout: Fixture.timeout))
        launcher.tap()
        let assistantTile = app.buttons["intent.menu.assistant"]
        XCTAssertTrue(assistantTile.waitForExistence(timeout: Fixture.timeout))
        assistantTile.tap()
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
    func testWorkspaceBlockOpensWorkspaceOverview() {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-assistant-workspace-links"]
        app.launch()
        let launcher = app.buttons["intent.menu.open"]
        XCTAssertTrue(launcher.waitForExistence(timeout: Fixture.timeout))
        launcher.tap()
        let assistantTile = app.buttons["intent.menu.assistant"]
        XCTAssertTrue(assistantTile.waitForExistence(timeout: Fixture.timeout))
        assistantTile.tap()
        let link = app.buttons["assistant.workspace.demo-ws-flaky-tests"]
        XCTAssertTrue(link.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(link.label.contains(Fixture.workspaceTitle))
        XCTAssertFalse(app.buttons["assistant.workspace.missing-workspace"].isEnabled)
        XCTAssertTrue(app.staticTexts["Ready when you are."].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Assistant workspace links"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        link.tap()
        XCTAssertTrue(app.staticTexts["Test Stabilizer"].firstMatch.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(app.buttons["assistant.actions"].waitForNonExistence(timeout: Fixture.timeout))
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
        let launcher = app.buttons["intent.menu.open"]
        XCTAssertTrue(launcher.waitForExistence(timeout: Fixture.timeout))
        launcher.tap()
        let assistantTile = app.buttons["intent.menu.assistant"]
        XCTAssertTrue(assistantTile.waitForExistence(timeout: Fixture.timeout))
        assistantTile.tap()
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
