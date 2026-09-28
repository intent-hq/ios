import XCTest

nonisolated final class WorkspaceChangesUITests: XCTestCase {
    private enum Fixture {
        static let workspaceTitle = "Add usage analytics dashboard"
        static let timeout: TimeInterval = 30
        static let scrollAttempts = 4
        static let maximumInitialLineOffset: CGFloat = 100
        static let maximumLeadingInset: CGFloat = 40
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
        reveal(unstaged, in: app)
        capture(app, name: "workspace-changes")
        unstaged.tap()
        XCTAssertTrue(app.navigationBars["Unstaged Changes"].waitForExistence(timeout: Fixture.timeout))
        assertDiffLine(in: app, containing: "let enabled = true")
        capture(app, name: "unstaged-diff")
        app.buttons["Done"].tap()
        let staged = app.staticTexts["Tests/AnalyticsTests.swift"].firstMatch
        reveal(staged, in: app)
        staged.tap()
        XCTAssertTrue(app.navigationBars["Staged Changes"].waitForExistence(timeout: Fixture.timeout))
        assertDiffLine(in: app, containing: "let staged = true")
        app.buttons["Done"].tap()
        let commit = app.staticTexts["feat: add usage analytics"].firstMatch
        reveal(commit, in: app)
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
        let staged = app.staticTexts["Tests/MobileAnalyticsTests.swift"].firstMatch
        reveal(staged, in: app)
        let unstaged = app.staticTexts["Sources/Analytics.swift"].firstMatch
        reveal(unstaged, in: app, towardTop: true)
        XCTAssertFalse(app.staticTexts["feat: add usage analytics"].exists)
        capture(app, name: "submodule-changes")
        unstaged.tap()
        assertDiffLine(in: app, containing: "let mobile = true")
        capture(app, name: "submodule-unstaged-diff")
        app.buttons["Done"].tap()
        reveal(staged, in: app)
        staged.tap()
        assertDiffLine(in: app, containing: "let mobileStaged = true")
        app.buttons["Done"].tap()
        reveal(commit, in: app)
        commit.tap()
        assertDiffLine(in: app, containing: "let mobileCount = 0")
        assertDiffLine(in: app, containing: "let mobileCount = 1")
        capture(app, name: "submodule-commit-diff")
        app.buttons["Done"].tap()
        selectRepository("Main repository", in: app)
        let mainStaged = app.staticTexts["Tests/AnalyticsTests.swift"].firstMatch
        reveal(mainStaged, in: app)
        XCTAssertFalse(commit.exists)
        reveal(unstaged, in: app, towardTop: true)
        unstaged.tap()
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
        reveal(changes, in: app)
        changes.tap()
        return app
    }

    @MainActor
    private func selectRepository(_ name: String, in app: XCUIApplication) {
        let picker = app.buttons["changes.repository"].firstMatch
        reveal(picker, in: app, towardTop: true)
        picker.tap()
        let option = app.buttons[name].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: Fixture.timeout))
        option.tap()
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        for _ in 0..<Fixture.scrollAttempts {
            if element.exists, element.isHittable { return }
            if towardTop { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(element.waitForExistence(timeout: Fixture.timeout))
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func assertDiffLine(in app: XCUIApplication, containing text: String) {
        let line = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "label CONTAINS %@ AND (label BEGINSWITH 'Addition,' OR label BEGINSWITH 'Deletion,')",
                text
            )).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: Fixture.timeout))
        let viewport = app.scrollViews["changes.diff.scroll"].firstMatch
        XCTAssertTrue(viewport.exists)
        XCTAssertTrue(line.isHittable)
        XCTAssertGreaterThanOrEqual(line.frame.minY, viewport.frame.minY)
        XCTAssertLessThan(line.frame.minY - viewport.frame.minY, Fixture.maximumInitialLineOffset)
        XCTAssertLessThan(line.frame.minX - viewport.frame.minX, Fixture.maximumLeadingInset)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
