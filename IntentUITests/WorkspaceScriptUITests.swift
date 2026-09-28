import XCTest

nonisolated final class WorkspaceScriptUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

    @MainActor
    func testLaunchingServerFromSectionOpensAndRetainsBrowser() {
        let app = launchWorkspace()
        let script = app.buttons["workspace.script.demo-server"]
        for _ in 0..<5 where !script.isHittable { app.swipeUp() }
        XCTAssertTrue(script.waitForExistence(timeout: Self.timeout))
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
        let command = app.buttons["workspace.script.menu.demo-check"]
        XCTAssertTrue(command.waitForExistence(timeout: Self.timeout))
        command.tap()
        let commandRow = app.buttons["workspace.script.demo-check"]
        for _ in 0..<5 where !commandRow.isHittable { app.swipeUp() }
        XCTAssertTrue(commandRow.waitForExistence(timeout: Self.timeout))
        let finished = NSPredicate(format: "label CONTAINS %@", "Finished")
        expectation(for: finished, evaluatedWith: commandRow)
        waitForExpectations(timeout: Self.timeout)
        XCTAssertFalse(app.textFields["Browser URL"].exists)
        openScriptsMenu(in: app)
        let server = app.buttons["workspace.script.menu.demo-server"]
        XCTAssertTrue(server.waitForExistence(timeout: Self.timeout))
        server.tap()
        assertServerBrowser(in: app)
    }

    @MainActor
    private func launchWorkspace() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "--demo-browsers", "--demo-scripts"]
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
