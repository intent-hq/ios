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
        let app = openChanges()
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
    func testRepositorySelectionScopesFilesAndCommitDiffs() {
        let app = openChanges()
        selectRepository("ios", in: app)
        let commit = app.staticTexts["feat: add mobile analytics"].firstMatch
        XCTAssertTrue(commit.waitForExistence(timeout: Fixture.timeout))
        XCTAssertFalse(app.staticTexts["feat: add usage analytics"].exists)
        capture(app, name: "submodule-changes")
        app.staticTexts["Sources/Analytics.swift"].firstMatch.tap()
        assertDiffLine(in: app, containing: "let mobile = true")
        capture(app, name: "submodule-unstaged-diff")
        app.buttons["Done"].tap()
        app.staticTexts["Tests/MobileAnalyticsTests.swift"].firstMatch.tap()
        assertDiffLine(in: app, containing: "let mobileStaged = true")
        app.buttons["Done"].tap()
        if !commit.isHittable { app.swipeUp() }
        commit.tap()
        assertDiffLine(in: app, containing: "let mobileCount = 0")
        assertDiffLine(in: app, containing: "let mobileCount = 1")
        capture(app, name: "submodule-commit-diff")
        app.buttons["Done"].tap()
        selectRepository("Main repository", in: app)
        let mainCommit = app.staticTexts["feat: add usage analytics"].firstMatch
        XCTAssertTrue(mainCommit.waitForExistence(timeout: Fixture.timeout))
        XCTAssertFalse(commit.exists)
        app.staticTexts["Sources/Analytics.swift"].firstMatch.tap()
        assertDiffLine(in: app, containing: "let enabled = true")
    }

    @MainActor
    private func openChanges() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data"]
        app.launch()
        let workspace = app.staticTexts[Fixture.workspaceTitle].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))
        workspace.tap()
        let changes = app.buttons["Changes"].firstMatch
        XCTAssertTrue(changes.waitForExistence(timeout: Fixture.timeout))
        changes.tap()
        return app
    }

    @MainActor
    private func selectRepository(_ name: String, in app: XCUIApplication) {
        let picker = app.buttons["changes.repository"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: Fixture.timeout))
        if !picker.isHittable { app.swipeDown() }
        picker.tap()
        let option = app.buttons[name].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: Fixture.timeout))
        option.tap()
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
