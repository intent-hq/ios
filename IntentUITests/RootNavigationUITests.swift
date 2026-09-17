import XCTest

nonisolated final class RootNavigationUITests: XCTestCase {
    private enum Demo {
        static let workspace = "Add usage analytics dashboard"
        static let agent = "Dashboard Implementor"
        static let conversationFragment = "more than 90 days"
        static let note = "Spec"
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
    func testCompactConversationBackReselectAndNoteNavigation() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        exerciseRootNavigation(in: launchDemoApp())
    }

    @MainActor
    func testRegularConversationBackReselectAndNoteNavigation() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        XCUIDevice.shared.orientation = .landscapeLeft
        exerciseRootNavigation(in: launchDemoApp())
    }

    @MainActor
    private func launchDemoApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data"]
        app.launch()
        return app
    }

    @MainActor
    private func exerciseRootNavigation(in app: XCUIApplication) {
        let workspace = app.staticTexts[Demo.workspace].firstMatch
        if !workspace.waitForExistence(timeout: 30) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(workspace.waitForExistence(timeout: 15))
        }
        workspace.tap()

        let agent = app.staticTexts[Demo.agent].firstMatch
        XCTAssertTrue(waitForHittable(agent))
        openConversation(byTapping: agent, in: app)
        navigateBackFromConversation(in: app)
        XCTAssertTrue(waitForHittable(agent))

        openConversation(byTapping: agent, in: app)
        navigateBackFromConversation(in: app)
        XCTAssertTrue(waitForHittable(agent))

        app.buttons["Context"].firstMatch.tap()
        let note = app.staticTexts[Demo.note].firstMatch
        XCTAssertTrue(waitForHittable(note))
        note.tap()
        let noteBar = app.navigationBars[Demo.note].firstMatch
        XCTAssertTrue(noteBar.waitForExistence(timeout: 15))

        let noteBack = noteBar.buttons[Demo.workspace].firstMatch
        XCTAssertTrue(noteBack.waitForExistence(timeout: 5))
        noteBack.tap()
        XCTAssertTrue(waitForHittable(note))
    }

    @MainActor
    private func openConversation(byTapping agent: XCUIElement, in app: XCUIApplication) {
        agent.tap()
        let message = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS[c] %@", Demo.conversationFragment))
            .firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 15))
    }

    @MainActor
    private func navigateBackFromConversation(in app: XCUIApplication) {
        let agentsBack = app.navigationBars.buttons["Agents"].firstMatch
        if agentsBack.exists {
            agentsBack.tap()
        } else {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    @MainActor
    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        return result == .completed
    }
}
