import XCTest

/// ios#462: a failed first read shows an error with Retry, and Retry loads the list.
nonisolated final class ListLoadFailureUITests: XCTestCase {
    private enum Fixture {
        static let timeout: TimeInterval = 30
        static let workspaceRow = "workspace.row.demo-ws-dashboard"
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
    func testFailedAgentAndNoteReadsShowRetryInBothThemes() {
        for appearance in ["light", "dark"] {
            let app = launch(failures: "agent-list,note-list", appearance: appearance)
            let workspace = app.buttons[Fixture.workspaceRow]
            XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))
            workspace.tap()

            assertFailureThenRetry(prefix: "workspace.agents", in: app, capture: "load-failure-agents-\(appearance)")
            XCTAssertFalse(app.staticTexts["No Agents"].exists, "A loaded workspace's agents replace the error")

            let context = app.buttons["Context"].firstMatch
            XCTAssertTrue(context.waitForExistence(timeout: Fixture.timeout))
            context.tap()
            assertFailureThenRetry(prefix: "notes", in: app, capture: "load-failure-notes-\(appearance)")
            XCTAssertTrue(app.buttons["workspace.note.demo-note-spec"].waitForExistence(timeout: Fixture.timeout))
            app.terminate()
        }
    }

    @MainActor
    func testFailedWorkspaceListShowsRetryInsteadOfEmptyState() {
        let app = launch(failures: "workspace-list", appearance: "light")
        assertFailureThenRetry(prefix: "workspaceList", in: app, capture: "load-failure-workspaces-light")
        XCTAssertTrue(app.buttons[Fixture.workspaceRow].waitForExistence(timeout: Fixture.timeout))
        XCTAssertFalse(app.staticTexts["No Workspaces"].exists)
    }

    @MainActor
    private func launch(failures: String, appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "--demo-failures=\(failures)", "-appThemePreference", appearance]
        app.launch()
        return app
    }

    @MainActor
    private func assertFailureThenRetry(prefix: String, in app: XCUIApplication, capture name: String) {
        let failure = app.descendants(matching: .any)["\(prefix).loadFailure"].firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: Fixture.timeout), "\(prefix) shows its load error")
        let retry = app.buttons["\(prefix).loadFailure.retry"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(retry.isHittable)
        capture(app, name: name)
        retry.tap()
        XCTAssertTrue(failure.waitForNonExistence(timeout: Fixture.timeout), "Retry loads \(prefix)")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
