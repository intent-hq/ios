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
}
