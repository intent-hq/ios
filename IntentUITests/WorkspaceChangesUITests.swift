import XCTest

nonisolated final class WorkspaceChangesUITests: XCTestCase {
    private enum Fixture {
        static let workspaceTitle = "Add usage analytics dashboard"
        static let timeout: TimeInterval = 30
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
    func testChangesTabOpensStagedUnstagedAndCommitDiffs() {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data"]
        app.launch()
        let workspace = app.staticTexts[Fixture.workspaceTitle].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))
        workspace.tap()
        let changes = app.buttons["Changes"].firstMatch
        XCTAssertTrue(changes.waitForExistence(timeout: Fixture.timeout))
        changes.tap()
        let unstaged = app.staticTexts["Sources/Analytics.swift"].firstMatch
        XCTAssertTrue(unstaged.waitForExistence(timeout: Fixture.timeout))
        capture(app, name: "workspace-changes")
        unstaged.tap()
        XCTAssertTrue(app.navigationBars["Unstaged Changes"].waitForExistence(timeout: Fixture.timeout))
        assertDiffLine(in: app, containing: "let enabled = true")
        capture(app, name: "unstaged-diff")
        app.buttons["Done"].tap()
        let staged = app.staticTexts["Tests/AnalyticsTests.swift"].firstMatch
        XCTAssertTrue(staged.waitForExistence(timeout: Fixture.timeout))
        staged.tap()
        XCTAssertTrue(app.navigationBars["Staged Changes"].waitForExistence(timeout: Fixture.timeout))
        assertDiffLine(in: app, containing: "let staged = true")
        app.buttons["Done"].tap()
        let commit = app.staticTexts["feat: add usage analytics"].firstMatch
        if !commit.isHittable { app.swipeUp() }
        XCTAssertTrue(commit.waitForExistence(timeout: Fixture.timeout))
        commit.tap()
        XCTAssertTrue(app.navigationBars["Commit Changes"].waitForExistence(timeout: Fixture.timeout))
        assertDiffLine(in: app, containing: "let count = 1")
        capture(app, name: "commit-diff")
    }

    @MainActor
    private func assertDiffLine(in app: XCUIApplication, containing text: String) {
        let line = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: Fixture.timeout))
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
