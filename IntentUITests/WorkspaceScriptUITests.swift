import XCTest

nonisolated final class WorkspaceScriptUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

    // iOS 27 native submenus drop action identifiers, including identifiers on Label.
    // Match the exact demo names from DemoBrowserFixtures / DemoRepositoryScriptFixtures;
    // keep row identifiers and observable launch/swipe behavior as the test contracts.
    private enum Fixture {
        static let server = "Web server"
        static let command = "Check project"
        static let verification = "Gradient browser verification"
        static let dev = "dev"
        static let build = "build"
        static let test = "test"
    }

    @MainActor
    func testFirstLaunchAddsServerToSectionAndRetainsBrowser() {
        let app = launchWorkspace()
        let script = app.buttons["workspace.script.demo-server"]
        XCTAssertFalse(script.exists)
        openScriptsMenu(in: app)
        let server = app.buttons[Fixture.server]
        XCTAssertTrue(server.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.buttons[Fixture.command].exists)
        server.tap()
        assertServerBrowser(in: app)
        app.buttons["Done"].tap()
        for _ in 0..<5 where !script.isHittable { app.swipeUp() }
        XCTAssertTrue(script.waitForExistence(timeout: Self.timeout))
        XCTAssertFalse(app.buttons["workspace.script.demo-check"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "workspace-scripts-section"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        script.tap()
        assertServerBrowser(in: app)
        app.buttons["Done"].tap()
        let browser = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", ":4321")).firstMatch
        for _ in 0..<5 where !browser.isHittable { app.swipeUp() }
        XCTAssertTrue(browser.waitForExistence(timeout: Self.timeout))
        browser.tap()
        assertServerBrowser(in: app)
    }

    @MainActor
    func testScriptSubmenuLaunchesServerAndCommandDoesNotOpenBrowser() {
        let app = launchWorkspace()
        openScriptsMenu(in: app)
        let command = app.buttons[Fixture.command]
        XCTAssertTrue(command.waitForExistence(timeout: Self.timeout))
        command.tap()
        let commandRow = app.buttons["workspace.script.demo-check"]
        for _ in 0..<5 where !commandRow.isHittable { app.swipeUp() }
        XCTAssertTrue(commandRow.waitForExistence(timeout: Self.timeout))
        let finished = NSPredicate(format: "label CONTAINS %@", "Finished")
        expectation(for: finished, evaluatedWith: commandRow)
        waitForExpectations(timeout: Self.timeout)
        XCTAssertFalse(app.textFields["Browser URL"].exists)
        XCTAssertFalse(app.buttons["workspace.script.demo-server"].exists)
        openScriptsMenu(in: app)
        let server = app.buttons[Fixture.server]
        XCTAssertTrue(server.waitForExistence(timeout: Self.timeout))
        server.tap()
        assertServerBrowser(in: app)
    }

    @MainActor
    func testRepositoryScriptsAppearBesideSavedCommandAndRegisterOnFirstLaunch() {
        let app = launchWorkspace(repositoryScripts: true)
        openScriptsMenu(in: app)
        XCTAssertTrue(app.buttons[Fixture.verification].exists)
        let dev = app.buttons[Fixture.dev]
        XCTAssertTrue(dev.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.buttons[Fixture.build].exists)
        XCTAssertTrue(app.buttons[Fixture.test].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "workspace-repository-scripts-menu"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        dev.tap()
        assertServerBrowser(in: app)
        app.buttons["Done"].tap()
        let row = app.buttons["workspace.script.demo-repo-dev"]
        for _ in 0..<5 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: Self.timeout))
        XCTAssertFalse(app.buttons["workspace.script.demo-verification"].exists)
        XCTAssertFalse(app.buttons["workspace.script.manifest:package.json:build"].exists)
    }

    @MainActor
    func testSwipeStopsServerAndDeletesFinishedScript() {
        let app = launchWorkspace()
        openScriptsMenu(in: app)
        app.buttons[Fixture.server].tap()
        assertServerBrowser(in: app)
        app.buttons["Done"].tap()
        let row = app.buttons["workspace.script.demo-server"]
        for _ in 0..<5 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: Self.timeout))
        row.swipeLeft()
        let stop = app.buttons["workspace.script.stop.demo-server"]
        XCTAssertTrue(stop.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["workspace.script.delete.demo-server"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "workspace-script-stop-delete-actions"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        stop.tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Finished"), evaluatedWith: row)
        waitForExpectations(timeout: Self.timeout)
        XCTAssertFalse(app.textFields["Browser URL"].exists)
        row.swipeLeft()
        let delete = app.buttons["workspace.script.delete.demo-server"]
        XCTAssertTrue(delete.waitForExistence(timeout: Self.timeout))
        XCTAssertFalse(stop.exists)
        delete.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: Self.timeout))
        openScriptsMenu(in: app)
        XCTAssertFalse(app.buttons[Fixture.server].exists)
        XCTAssertTrue(app.buttons[Fixture.command].exists)
    }

    @MainActor
    func testSwipingBetweenResourceTypesClosesPreviousMenuAndTapDismissesWithoutOpening() {
        let app = launchWorkspace()
        openScriptsMenu(in: app)
        app.buttons[Fixture.server].tap()
        assertServerBrowser(in: app)
        app.buttons["Done"].tap()
        let script = app.buttons["workspace.script.demo-server"]
        for _ in 0..<5 where !script.isHittable { app.swipeUp() }
        XCTAssertTrue(script.waitForExistence(timeout: Self.timeout))
        app.swipeUp()
        let browser = app.buttons["browser.row.tab:demo-agent-browser"]
        XCTAssertTrue(browser.isHittable)
        XCTAssertTrue(script.isHittable)
        browser.swipeLeft()
        let browserDelete = app.buttons["browser.delete.tab:demo-agent-browser"]
        XCTAssertTrue(browserDelete.waitForExistence(timeout: Self.timeout))
        script.swipeLeft()
        let stop = app.buttons["workspace.script.stop.demo-server"]
        XCTAssertTrue(stop.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(browserDelete.waitForNonExistence(timeout: Self.timeout))
        browser.tap()
        XCTAssertTrue(stop.waitForNonExistence(timeout: Self.timeout))
        XCTAssertFalse(app.textFields["Browser URL"].exists)
        browser.tap()
        XCTAssertTrue(app.textFields["Browser URL"].waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["Done"].exists)
    }

    @MainActor
    func testDeleteRunningRepositoryScriptAllowsFreshLaunchFromMenu() {
        let app = launchWorkspace(repositoryScripts: true)
        openScriptsMenu(in: app)
        app.buttons[Fixture.dev].tap()
        assertServerBrowser(in: app)
        app.buttons["Done"].tap()
        let row = app.buttons["workspace.script.demo-repo-dev"]
        for _ in 0..<5 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: Self.timeout))
        row.swipeLeft()
        XCTAssertTrue(app.buttons["workspace.script.stop.demo-repo-dev"].waitForExistence(timeout: Self.timeout))
        app.buttons["workspace.script.delete.demo-repo-dev"].tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: Self.timeout))
        openScriptsMenu(in: app)
        let dev = app.buttons[Fixture.dev]
        XCTAssertTrue(dev.waitForExistence(timeout: Self.timeout))
        dev.tap()
        assertServerBrowser(in: app)
    }

    @MainActor
    func testVerticalDragOnScriptRowStillScrollsWorkspace() {
        // Extra completed scripts provide real scroll range on tall screens at default text size.
        let app = launchWorkspace(longScriptList: true)
        openScriptsMenu(in: app)
        app.buttons[Fixture.command].tap()
        let row = app.buttons["workspace.script.demo-check"]
        for _ in 0..<5 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: Self.timeout))
        // Leave the top scroll boundary before testing a downward drag.
        app.swipeUp()
        XCTAssertTrue(app.frame.contains(row.frame))
        let startingY = row.frame.minY
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 80)))
        XCTAssertGreaterThan(row.frame.minY, startingY + 20)
        XCTAssertFalse(app.buttons["workspace.script.delete.demo-check"].exists)
        XCTAssertFalse(app.textFields["Browser URL"].exists)
    }

    @MainActor
    private func launchWorkspace(repositoryScripts: Bool = false, longScriptList: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "--demo-browsers", repositoryScripts ? "--demo-repo-scripts" : "--demo-scripts"]
        if longScriptList { app.launchArguments.append("--demo-long-script-list") }
        app.launch()
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
        workspace.tap()
        XCTAssertTrue(app.buttons["Workspace actions"].waitForExistence(timeout: Self.timeout))
        return app
    }

    @MainActor
    private func openScriptsMenu(in app: XCUIApplication) {
        app.buttons["Workspace actions"].tap()
        let scripts = app.buttons["workspace.scripts.menu"]
        XCTAssertTrue(scripts.waitForExistence(timeout: Self.timeout))
        scripts.tap()
    }

    @MainActor
    private func assertServerBrowser(in app: XCUIApplication) {
        let address = app.textFields["Browser URL"]
        XCTAssertTrue(address.waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(address.value as? String, "http://127.0.0.1:4321")
        XCTAssertTrue(app.buttons["Done"].exists)
    }
}
