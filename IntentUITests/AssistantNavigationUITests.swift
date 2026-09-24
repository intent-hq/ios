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
}
