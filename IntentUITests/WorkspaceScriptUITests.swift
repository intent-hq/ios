import XCTest

nonisolated final class WorkspaceScriptUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

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
        XCTAssertTrue(server.appears(timeout: Self.timeout))
        XCTAssertTrue(app.buttons[Fixture.command].exists)
        server.tap()
        assertServerBrowser(in: app)
        closeBrowser(in: app)
        revealResource(script, in: app)
        XCTAssertFalse(app.buttons["workspace.script.demo-check"].exists)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "workspace-scripts-section"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        script.tap()
        assertServerBrowser(in: app)
        closeBrowser(in: app)
        let browser = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", ":4321")).firstMatch
        revealResource(browser, in: app)
        browser.tap()
        assertServerBrowser(in: app)
    }

    @MainActor
    func testScriptSubmenuLaunchesServerAndCommandDoesNotOpenBrowser() {
        let app = launchWorkspace()
        openScriptsMenu(in: app)
        let command = app.buttons[Fixture.command]
        XCTAssertTrue(command.appears(timeout: Self.timeout))
        command.tap()
        let commandRow = app.buttons["workspace.script.demo-check"]
        revealResource(commandRow, in: app)
        let finished = NSPredicate(format: "label CONTAINS %@", "Finished")
        expectation(for: finished, evaluatedWith: commandRow)
        waitForExpectations(timeout: Self.timeout)
        XCTAssertFalse(app.textFields["Browser URL"].exists)
        XCTAssertFalse(app.buttons["workspace.script.demo-server"].exists)
        openScriptsMenu(in: app)
        let server = app.buttons[Fixture.server]
        XCTAssertTrue(server.appears(timeout: Self.timeout))
        server.tap()
        assertServerBrowser(in: app)
    }

    @MainActor
    func testRepositoryScriptsAppearBesideSavedCommandAndRegisterOnFirstLaunch() {
        let app = launchWorkspace(repositoryScripts: true)
        openScriptsMenu(in: app)
        XCTAssertTrue(app.buttons[Fixture.verification].exists)
        let dev = app.buttons[Fixture.dev]
        XCTAssertTrue(dev.appears(timeout: Self.timeout))
        XCTAssertTrue(app.buttons[Fixture.build].exists)
        XCTAssertTrue(app.buttons[Fixture.test].exists)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "workspace-repository-scripts-menu"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        dev.tap()
        assertServerBrowser(in: app)
        closeBrowser(in: app)
        let row = app.buttons["workspace.script.demo-repo-dev"]
        revealResource(row, in: app)
        XCTAssertFalse(app.buttons["workspace.script.demo-verification"].exists)
        XCTAssertFalse(app.buttons["workspace.script.manifest:package.json:build"].exists)
    }

    @MainActor
    func testSwipeStopsServerAndDeletesFinishedScript() {
        let app = launchWorkspace()
        openScriptsMenu(in: app)
        app.buttons[Fixture.server].tap()
        assertServerBrowser(in: app)
        closeBrowser(in: app)
        let row = app.buttons["workspace.script.demo-server"]
        revealResource(row, in: app)
        revealActions(on: row)
        let stop = app.buttons["workspace.script.stop.demo-server"]
        XCTAssertTrue(stop.appears(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["workspace.script.delete.demo-server"].exists)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "workspace-script-stop-delete-actions"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        stop.tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Finished"), evaluatedWith: row)
        waitForExpectations(timeout: Self.timeout)
        XCTAssertFalse(app.textFields["Browser URL"].exists)
        revealActions(on: row)
        let delete = app.buttons["workspace.script.delete.demo-server"]
        XCTAssertTrue(delete.appears(timeout: Self.timeout))
        XCTAssertFalse(stop.exists)
        delete.tap()
        XCTAssertTrue(row.disappears(timeout: Self.timeout))
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
        closeBrowser(in: app)
        let script = app.buttons["workspace.script.demo-server"]
        revealResource(script, in: app)
        app.scrollViews["workspace.detail.scroll"].swipeUp()
        let browser = app.buttons["browser.row.tab:demo-agent-browser"]
        XCTAssertTrue(browser.isHittable)
        XCTAssertTrue(script.isHittable)
        revealActions(on: browser)
        let browserDelete = app.buttons["browser.delete.tab:demo-agent-browser"]
        XCTAssertTrue(browserDelete.appears(timeout: Self.timeout))
        revealActions(on: script)
        let stop = app.buttons["workspace.script.stop.demo-server"]
        XCTAssertTrue(stop.appears(timeout: Self.timeout))
        XCTAssertTrue(browserDelete.disappears(timeout: Self.timeout))
        browser.tap()
        XCTAssertTrue(stop.disappears(timeout: Self.timeout))
        XCTAssertFalse(app.textFields["Browser URL"].exists)
        browser.tap()
        XCTAssertTrue(app.textFields["Browser URL"].appears(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["Done"].exists)
    }

    @MainActor
    func testDeleteRunningRepositoryScriptAllowsFreshLaunchFromMenu() {
        let app = launchWorkspace(repositoryScripts: true)
        openScriptsMenu(in: app)
        app.buttons[Fixture.dev].tap()
        assertServerBrowser(in: app)
        closeBrowser(in: app)
        let row = app.buttons["workspace.script.demo-repo-dev"]
        revealResource(row, in: app)
        revealActions(on: row)
        XCTAssertTrue(app.buttons["workspace.script.stop.demo-repo-dev"].appears(timeout: Self.timeout))
        app.buttons["workspace.script.delete.demo-repo-dev"].tap()
        XCTAssertTrue(row.disappears(timeout: Self.timeout))
        openScriptsMenu(in: app)
        let dev = app.buttons[Fixture.dev]
        XCTAssertTrue(dev.appears(timeout: Self.timeout))
        dev.tap()
        assertServerBrowser(in: app)
    }

    @MainActor
    func testVerticalDragOnScriptRowStillScrollsWorkspace() {
        let app = launchWorkspace(longScriptList: true)
        openScriptsMenu(in: app)
        app.buttons[Fixture.command].tap()
        let row = app.buttons["workspace.script.demo-check"]
        revealResource(row, in: app)
        app.scrollViews["workspace.detail.scroll"].swipeUp()
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
        let app = XCUIApplication.intent()
        app.launchArguments = ["--demo-data", "--demo-browsers", repositoryScripts ? "--demo-repo-scripts" : "--demo-scripts"]
        if longScriptList { app.launchArguments.append("--demo-long-script-list") }
        app.launch()
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(workspace.appears(timeout: Self.timeout))
        workspace.tap()
        XCTAssertTrue(app.buttons["Workspace actions"].appears(timeout: Self.timeout))
        return app
    }

    @MainActor
    private func openScriptsMenu(in app: XCUIApplication) {
        app.buttons["Workspace actions"].tap()
        let scripts = app.buttons["workspace.scripts.menu"]
        XCTAssertTrue(scripts.appears(timeout: Self.timeout))
        scripts.tap()
    }

    @MainActor
    private func closeBrowser(in app: XCUIApplication) {
        app.buttons["Done"].tap()
        XCTAssertTrue(app.textFields["Browser URL"].disappears(timeout: Self.timeout))
    }

    @MainActor
    private func revealResource(_ resource: XCUIElement, in app: XCUIApplication) {
        let detail = app.scrollViews["workspace.detail.scroll"]
        XCTAssertTrue(detail.appears(timeout: Self.timeout))
        for _ in 0..<5 where !resource.isHittable { detail.swipeUp() }
        XCTAssertTrue(resource.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
    }

    @MainActor
    private func revealActions(on resource: XCUIElement) {
        XCTAssertTrue(resource.isHittable)
        let start = resource.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        let end = resource.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func assertServerBrowser(in app: XCUIApplication) {
        let address = app.textFields["Browser URL"]
        XCTAssertTrue(address.appears(timeout: Self.timeout))
        XCTAssertEqual(address.value as? String, "http://127.0.0.1:4321")
        XCTAssertTrue(app.buttons["Done"].exists)
    }
}
