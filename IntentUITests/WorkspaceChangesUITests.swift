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
        let app = openChanges(largeText: true)
        let unstaged = app.buttons["changes.file.unstaged.Sources/Analytics.swift"].firstMatch
        reveal(unstaged, in: app)
        capture(app, name: "workspace-changes")
        unstaged.tap()
        XCTAssertTrue(app.navigationBars["Unstaged Changes"].waitForExistence(timeout: Fixture.timeout))
        assertDiffLine(in: app, containing: "let enabled = true")
        capture(app, name: "unstaged-diff")
        app.buttons["Done"].tap()
        let staged = app.buttons["changes.file.staged.Tests/AnalyticsTests.swift"].firstMatch
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
        verifyCommitNavigation(in: app)
    }

    @MainActor
    private func verifyCommitNavigation(in app: XCUIApplication) {
        let source = app.buttons["commit.file.Sources/Analytics.swift"].firstMatch
        source.tap()
        XCTAssertEqual(source.value as? String, "Collapsed")
        app.buttons["commit.view.Details"].tap()
        XCTAssertTrue(app.scrollViews["commit.details"].waitForExistence(timeout: Fixture.timeout))
        app.buttons["commit.copy"].tap()
        XCTAssertEqual(app.buttons["commit.copy"].label, "Copied")
        capture(app, name: "commit-details")
        app.buttons["commit.view.Changes"].tap()
        XCTAssertEqual(source.value as? String, "Collapsed")
        let tests = app.buttons["commit.file.Tests/AnalyticsTests.swift"].firstMatch
        reveal(tests, in: app)
        tests.tap()
        let jump = app.buttons["commit.jump"]
        XCTAssertTrue(jump.waitForNonExistence(timeout: Fixture.timeout), "All collapsed files fit in the viewport")
        capture(app, name: "commit-files-fit")
        source.tap()
        reveal(tests, in: app)
        tests.tap()
        XCTAssertTrue(jump.waitForExistence(timeout: Fixture.timeout), "Expanded diffs extend below the viewport")
        capture(app, name: "commit-files-offscreen")
        jump.tap()
        capture(app, name: "commit-file-picker")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: Fixture.timeout))
        search.tap()
        search.typeText("no-such-file")
        XCTAssertFalse(app.buttons["commit.jump.file.Sources/Analytics.swift"].exists)
        search.buttons["Clear text"].tap()
        search.typeText("Tests/")
        XCTAssertFalse(app.buttons["commit.jump.file.Sources/Analytics.swift"].exists)
        let testFile = app.buttons["commit.jump.file.Tests/AnalyticsTests.swift"].firstMatch
        XCTAssertTrue(testFile.waitForExistence(timeout: Fixture.timeout))
        capture(app, name: "commit-file-search")
        testFile.tap()
        XCTAssertTrue(app.buttons["commit.file.Tests/AnalyticsTests.swift"].waitForExistence(timeout: Fixture.timeout))
        app.buttons["commit.jump"].tap()
        app.buttons["commit.jump.file.Sources/Analytics.swift"].tap()
        XCTAssertEqual(source.value as? String, "Expanded")
        assertDiffLine(in: app, containing: "let count = 1")
    }

    @MainActor
    func testRepositorySelectionScopesFilesAndCommitDiffs() {
        let app = openChanges()
        selectRepository("ios", in: app)
        let commit = app.staticTexts["feat: add mobile analytics"].firstMatch
        let staged = app.buttons["changes.file.staged.Tests/MobileAnalyticsTests.swift"].firstMatch
        reveal(staged, in: app)
        let unstaged = app.buttons["changes.file.unstaged.Sources/Analytics.swift"].firstMatch
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
        app.buttons["commit.back"].tap()
        selectRepository("Main repository", in: app)
        let mainStaged = app.buttons["changes.file.staged.Tests/AnalyticsTests.swift"].firstMatch
        reveal(mainStaged, in: app)
        XCTAssertFalse(commit.exists)
        reveal(unstaged, in: app, towardTop: true)
        unstaged.tap()
        assertDiffLine(in: app, containing: "let enabled = true")
    }

    @MainActor
    func testSectionsCollapseIndependentlyAndReopen() {
        let app = openChanges()
        let unstaged = app.buttons["changes.section.unstaged"].firstMatch
        reveal(unstaged, in: app)
        unstaged.tap()
        XCTAssertEqual(unstaged.value as? String, "Collapsed")
        XCTAssertFalse(app.buttons["changes.folder.unstaged.Sources"].exists)
        let staged = app.buttons["changes.section.staged"].firstMatch
        reveal(staged, in: app)
        XCTAssertEqual(staged.value as? String, "Expanded")
        staged.tap()
        XCTAssertFalse(app.buttons["changes.folder.staged.Tests"].exists)
        let commits = app.buttons["changes.section.commits"].firstMatch
        reveal(commits, in: app)
        commits.tap()
        XCTAssertEqual(commits.value as? String, "Collapsed")
        XCTAssertFalse(app.staticTexts["feat: add usage analytics"].exists)
        capture(app, name: "collapsed-changes-sections")
        commits.tap()
        reveal(app.staticTexts["feat: add usage analytics"].firstMatch, in: app)
        reveal(staged, in: app, towardTop: true)
        staged.tap()
        reveal(app.buttons["changes.file.staged.Tests/AnalyticsTests.swift"].firstMatch, in: app)
        reveal(unstaged, in: app, towardTop: true)
        unstaged.tap()
        reveal(app.buttons["changes.file.unstaged.Sources/Analytics.swift"].firstMatch, in: app)
    }

    @MainActor
    func testNestedFoldersPreserveCollapseUntilRepositoryChanges() {
        let app = openChanges()
        let nested = app.buttons["changes.folder.unstaged.Sources/Analytics"].firstMatch
        let child = app.buttons["changes.file.unstaged.Sources/Analytics/Events.swift"].firstMatch
        reveal(nested, in: app)
        nested.tap()
        XCTAssertEqual(nested.value as? String, "Collapsed")
        XCTAssertFalse(child.exists)
        let parent = app.buttons["changes.folder.unstaged.Sources"].firstMatch
        reveal(parent, in: app, towardTop: true)
        parent.tap()
        XCTAssertFalse(nested.exists)
        parent.tap()
        reveal(nested, in: app)
        XCTAssertEqual(nested.value as? String, "Collapsed")
        let section = app.buttons["changes.section.unstaged"].firstMatch
        reveal(section, in: app, towardTop: true)
        section.tap()
        section.tap()
        reveal(nested, in: app)
        XCTAssertEqual(nested.value as? String, "Collapsed")
        capture(app, name: "nested-file-tree")
        selectRepository("ios", in: app)
        reveal(app.buttons["changes.file.unstaged.Sources/Analytics.swift"].firstMatch, in: app)
        selectRepository("Main repository", in: app)
        reveal(child, in: app)
        child.tap()
        XCTAssertTrue(app.navigationBars["Unstaged Changes"].waitForExistence(timeout: Fixture.timeout))
        assertDiffLine(in: app, containing: "let enabled = true")
    }

    @MainActor
    private func openChanges(largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]
        }
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
        XCTAssertLessThan(line.frame.minY - viewport.frame.minY, max(Fixture.maximumInitialLineOffset, line.frame.height * 6))
        XCTAssertLessThan(line.frame.minX - viewport.frame.minX, Fixture.maximumLeadingInset)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = UIDevice.current.userInterfaceIdiom == .pad ? XCUIScreen.main.screenshot() : app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

extension WorkspaceChangesUITests {
    @MainActor
    func testIPadCommitUsesMainPaneAndPreservesRepositoryInBothThemes() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad main pane navigation")
        defer { XCUIDevice.shared.orientation = .portrait }
        for appearance in ["light", "dark"] {
            XCUIDevice.shared.orientation = .landscapeLeft
            let app = XCUIApplication()
            app.launchArguments = ["--demo-data", "-appThemePreference", appearance]
            app.launch()
            let workspace = app.staticTexts[Fixture.workspaceTitle].firstMatch
            XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.timeout))
            workspace.tap()
            app.buttons["Changes"].firstMatch.tap()
            selectRepository("ios", in: app)
            let overviewWidth = app.scrollViews["workspace.detail.scroll"].firstMatch.frame.width
            openIPadCommit(in: app)
            assertIPadCommitPane(in: app, minimumWidth: overviewWidth * 0.95)
            capture(app, name: "ipad-commit-main-\(appearance)")
            app.buttons["commit.view.Details"].tap()
            XCTAssertTrue(app.scrollViews["commit.details"].waitForExistence(timeout: Fixture.timeout))
            app.buttons["commit.view.Changes"].tap()

            XCUIDevice.shared.orientation = .portrait
            assertIPadCommitPane(in: app)
            capture(app, name: "ipad-commit-portrait-\(appearance)")
            app.buttons["commit.back"].tap()
            XCTAssertTrue(app.buttons["changes.repository"].waitForExistence(timeout: Fixture.timeout))
            XCTAssertEqual(app.buttons["changes.repository"].value as? String, "ios")

            // A commit selected beside a conversation also belongs to the main pane.
            XCUIDevice.shared.orientation = .landscapeLeft
            let agents = app.buttons["Agents"].firstMatch
            reveal(agents, in: app, towardTop: true)
            agents.tap()
            let agent = app.buttons["workspace.agent.demo-agent-implementor"]
            reveal(agent, in: app)
            agent.tap()
            XCTAssertTrue(app.textViews["composer.textView"].waitForExistence(timeout: Fixture.timeout))
            app.buttons["Changes"].firstMatch.tap()
            selectRepository("ios", in: app)
            openIPadCommit(in: app)
            assertIPadCommitPane(in: app)
            XCTAssertTrue(app.buttons["changes.repository"].isHittable, "The sidebar stays interactive")
            capture(app, name: "ipad-commit-from-sidebar-\(appearance)")
            selectRepository("Main repository", in: app)
            XCTAssertTrue(app.buttons["commit.back"].waitForNonExistence(timeout: Fixture.timeout))
            XCTAssertTrue(app.textViews["composer.textView"].waitForExistence(timeout: Fixture.timeout))
            app.terminate()
        }
    }

    @MainActor
    private func openIPadCommit(in app: XCUIApplication) {
        let commit = app.staticTexts["feat: add mobile analytics"].firstMatch
        let overview = app.scrollViews["workspace.detail.scroll"].firstMatch
        for _ in 0..<Fixture.scrollAttempts {
            if commit.exists, commit.isHittable { break }
            overview.swipeUp()
        }
        XCTAssertTrue(commit.wait(for: \.isHittable, toEqual: true, timeout: Fixture.timeout))
        commit.tap()
        XCTAssertTrue(app.buttons["commit.back"].waitForExistence(timeout: Fixture.timeout))
        assertDiffLine(in: app, containing: "let mobileCount = 1")
    }

    @MainActor
    private func assertIPadCommitPane(in app: XCUIApplication, minimumWidth: CGFloat = 0) {
        let viewport = app.scrollViews["commit.changes.scroll"]
        XCTAssertTrue(viewport.wait(for: \.isHittable, toEqual: true, timeout: Fixture.timeout))
        XCTAssertGreaterThanOrEqual(viewport.frame.width, minimumWidth)
        XCTAssertGreaterThan(viewport.frame.maxY, app.frame.height * 0.85)
        XCTAssertLessThan(app.navigationBars["Commit Changes"].frame.minY, app.frame.height * 0.15)
        XCTAssertFalse(app.sheets.firstMatch.exists)
    }
}
