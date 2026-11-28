import XCTest

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
    func testFailedWorkspaceListShowsRetryInsteadOfEmptyState() {
        let app = launch(failures: "workspace-list", appearance: "light")
        assertFailureThenRetry(prefix: "workspaceList", in: app, capture: "load-failure-workspaces-light")
        XCTAssertTrue(app.buttons[Fixture.workspaceRow].appears(timeout: Fixture.timeout))
        XCTAssertFalse(app.staticTexts["No Workspaces"].exists)
    }

    @MainActor
    private func launch(failures: String, appearance: String) -> XCUIApplication {
        let app = XCUIApplication.intent()
        app.launchArguments = ["--demo-data", "--demo-failures=\(failures)", "-appThemePreference", appearance]
        app.launch()
        return app
    }

    @MainActor
    private func assertFailureThenRetry(prefix: String, in app: XCUIApplication, capture name: String) {
        let failure = app.descendants(matching: .any)["\(prefix).loadFailure"].firstMatch
        XCTAssertTrue(failure.appears(timeout: Fixture.timeout), "\(prefix) shows its load error")
        let retry = app.buttons["\(prefix).loadFailure.retry"].firstMatch
        XCTAssertTrue(retry.appears(timeout: Fixture.timeout))
        XCTAssertTrue(retry.isHittable)
        capture(app, name: name)
        retry.tap()
        XCTAssertTrue(failure.disappears(timeout: Fixture.timeout), "Retry loads \(prefix)")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
