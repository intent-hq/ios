import XCTest

nonisolated final class RootNavigationUITests: XCTestCase {
    private enum Demo {
        static let workspace = "Add usage analytics dashboard"
        static let agent = "Dashboard Implementor"
        static let conversationFragment = "more than 90 days"
        static let note = "Spec"
        static let soleAgentWorkspace = "Deflake payment integration tests"
        static let soleAgent = "Test Stabilizer"
        static let soleAgentConversationFragment = "End of the flake investigation"
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
    func testCompactExplicitSoleAgentWorkspaceEntryStaysOnOverview() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        exerciseExplicitSoleAgentWorkspaceEntry(in: launchDemoApp())
    }

    @MainActor
    func testRegularExplicitSoleAgentWorkspaceEntryStaysOnOverview() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        XCUIDevice.shared.orientation = .landscapeLeft
        exerciseExplicitSoleAgentWorkspaceEntry(in: launchDemoApp())
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
        let workspace = revealWorkspace(named: Demo.workspace, in: app)
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

        reenterWorkspace(named: Demo.workspace, in: app)
        XCTAssertTrue(waitForHittable(note), "Workspace re-entry must preserve the Context tab")
        XCTAssertFalse(noteBar.exists, "A saved note must not open on workspace re-entry")
        note.tap()
        XCTAssertTrue(noteBar.waitForExistence(timeout: 15), "Explicit note selection must still work")
    }

    @MainActor
    private func exerciseExplicitSoleAgentWorkspaceEntry(in app: XCUIApplication) {
        revealWorkspace(named: Demo.soleAgentWorkspace, in: app).tap()

        let agent = app.staticTexts[Demo.soleAgent].firstMatch
        XCTAssertTrue(
            waitForHittable(agent),
            "Explicit workspace entry must remain on the overview after its sole agent loads"
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(agent.isHittable, "A late agent update must not auto-forward the workspace entry")

        agent.tap()
        let message = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS[c] %@", Demo.soleAgentConversationFragment))
            .firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 15))

        navigateBackFromConversation(in: app, agentName: Demo.soleAgent, workspaceName: Demo.soleAgentWorkspace)
        XCTAssertTrue(waitForHittable(agent))
        reenterWorkspace(named: Demo.soleAgentWorkspace, in: app)
        XCTAssertTrue(waitForHittable(agent), "Saved conversation must not open on workspace re-entry")
        XCTAssertFalse(message.exists)
        agent.tap()
        XCTAssertTrue(message.waitForExistence(timeout: 15), "Explicit agent reselection must still work")
    }

    @MainActor
    private func reenterWorkspace(named name: String, in app: XCUIApplication) {
        if UIDevice.current.userInterfaceIdiom == .phone {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        } else {
            let otherWorkspace = name == Demo.workspace ? Demo.soleAgentWorkspace : Demo.workspace
            revealWorkspace(named: otherWorkspace, in: app).tap()
            XCTAssertTrue(waitForHittable(app.buttons["Context"].firstMatch))
        }
        let workspace = revealWorkspace(named: name, in: app)
        XCTAssertTrue(waitForHittable(workspace))
        workspace.tap()
    }

    @MainActor
    private func revealWorkspace(named name: String, in app: XCUIApplication) -> XCUIElement {
        let workspace = app.staticTexts[name].firstMatch
        if !workspace.waitForExistence(timeout: 30) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(workspace.waitForExistence(timeout: 15))
        }
        return workspace
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
    private func navigateBackFromConversation(
        in app: XCUIApplication, agentName: String = Demo.agent, workspaceName: String = Demo.workspace
    ) {
        let bar = app.navigationBars[agentName].firstMatch
        let workspaceBack = bar.buttons[workspaceName].firstMatch
        let back = workspaceBack.exists ? workspaceBack : bar.buttons["Back"].firstMatch
        XCTAssertTrue(waitForHittable(back), "Expected the conversation's Back button, not the sidebar toggle")
        back.tap()
        XCTAssertTrue(waitForHittable(app.buttons["Context"].firstMatch), "Back must reveal the workspace overview")
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
