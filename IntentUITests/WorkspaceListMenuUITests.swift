import XCTest

nonisolated final class WorkspaceListMenuUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

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
    private func launchWorkspaces() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-settings", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
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
    private func connection(_ name: String, in container: XCUIElement) -> XCUIElement {
        container.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "connection-switcher.connection.", name)).firstMatch
    }

    @MainActor
    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
