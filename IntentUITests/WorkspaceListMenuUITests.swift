import XCTest

nonisolated final class WorkspaceListMenuUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

    @MainActor
    func testEmptyWorkspaceButtonOpensCreationAndReturns() {
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        defer { XCUIDevice.shared.orientation = .portrait }
        for appearance in ["light", "dark"] {
            let app = launchWorkspaces(arguments: ["--demo-empty-workspaces", "-appThemePreference", appearance])
            let create = app.buttons["workspaces.empty.create"]
            XCTAssertTrue(create.waitForExistence(timeout: Self.timeout))
            XCTAssertTrue(create.isEnabled)
            capture(app, named: "empty-workspaces-\(appearance)")
            XCTAssertTrue(create.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
            create.tap()
            closeCreation(in: app)
            XCTAssertTrue(create.waitForExistence(timeout: Self.timeout))
            app.buttons["workspaces.search.open"].tap()
            let search = app.textFields["workspaces.search.field"]
            XCTAssertTrue(search.waitForExistence(timeout: Self.timeout))
            search.typeText("no-matching-workspace")
            XCTAssertTrue(create.waitForNonExistence(timeout: Self.timeout))
            app.buttons["workspaces.search.cancel"].tap()
            XCTAssertTrue(create.waitForExistence(timeout: Self.timeout))
            app.terminate()
        }
    }

    @MainActor
    func testNewWorkspaceMenuOpensCreationAndReturns() {
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        defer { XCUIDevice.shared.orientation = .portrait }
        for appearance in ["light", "dark"] {
            let app = launchWorkspaces(arguments: ["-appThemePreference", appearance])
            let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
            XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
            XCTAssertFalse(app.buttons["workspaces.empty.create"].exists)
            app.buttons["workspaces.menu"].tap()
            let create = app.buttons["workspaces.menu.create"]
            XCTAssertTrue(create.waitForExistence(timeout: Self.timeout))
            XCTAssertTrue(create.isEnabled)
            capture(app, named: "new-workspace-menu-\(appearance)")
            create.tap()
            closeCreation(in: app)
            XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
            XCTAssertTrue(app.buttons["workspaces.menu"].isHittable)
            app.terminate()
        }
    }

    @MainActor
    func testRecentAgentsOpensAndClosesExistingDrawer() {
        let app = launchWorkspaces()
        app.buttons["workspaces.menu"].tap()
        capture(app, named: "workspace-list-menu")
        app.buttons["Recent agents"].tap()
        let close = app.buttons["agent-history.close"]
        XCTAssertTrue(close.waitForExistence(timeout: Self.timeout))
        let heading = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Recent agents")).firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(heading.isHittable)
        capture(app, named: "workspace-menu-recent-agents")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["workspaces.menu"].isHittable)
    }

    @MainActor
    func testRecentConnectionsOpensSwitcherAndSelectsConnection() {
        let app = launchWorkspaces()
        app.buttons["workspaces.viewMode.Repo"].tap()
        app.buttons["workspaces.menu"].tap()
        app.buttons["Recent connections"].tap()
        let close = app.buttons["connection-switcher.close"]
        XCTAssertTrue(close.waitForExistence(timeout: Self.timeout))
        let studio = connection("Studio Mac", in: app)
        let travel = connection("Travel Mac", in: app)
        XCTAssertTrue(studio.isSelected)
        XCTAssertTrue(travel.isHittable)
        capture(app, named: "workspace-menu-recent-connections")
        studio.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["workspaces.viewMode.Repo"].isSelected)

        app.buttons["workspaces.menu"].tap()
        app.buttons["Recent connections"].tap()
        travel.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: Self.timeout))
        // iPad opens the selected connection in its own native window.
        let window = app.windows.firstMatch
        let menu = window.buttons["workspaces.menu"]
        if UIDevice.current.userInterfaceIdiom == .pad, !menu.isHittable {
            window.buttons["Show Sidebar"].tap()
        }
        menu.tap()
        app.buttons["Recent connections"].tap()
        XCTAssertTrue(connection("Travel Mac", in: window).isSelected)
        let activeClose = window.buttons["connection-switcher.close"]
        activeClose.tap()
        XCTAssertTrue(activeClose.waitForNonExistence(timeout: Self.timeout))
    }

    @MainActor
    private func launchWorkspaces(arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-settings", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += arguments
        app.launch()
        let menu = app.buttons["workspaces.menu"]
        if UIDevice.current.userInterfaceIdiom == .pad, !menu.waitForExistence(timeout: 2) {
            let showSidebar = app.buttons["Show Sidebar"]
            XCTAssertTrue(showSidebar.waitForExistence(timeout: Self.timeout))
            showSidebar.tap()
        }
        XCTAssertTrue(menu.waitForExistence(timeout: Self.timeout))
        return app
    }

    @MainActor
    private func closeCreation(in app: XCUIApplication) {
        let title = app.staticTexts["creation.repositoryTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: Self.timeout))
        app.buttons["creation.close"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: Self.timeout))
    }

    @MainActor
    private func connection(_ name: String, in container: XCUIElement) -> XCUIElement {
        container.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "connection-switcher.connection.", name)).firstMatch
    }

    @MainActor
    private func capture(_ app: XCUIApplication, named name: String) {
        let screenshot = UIDevice.current.userInterfaceIdiom == .pad ? XCUIScreen.main.screenshot() : app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
