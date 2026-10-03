import XCTest

nonisolated final class WorkspaceListMenuUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

    @MainActor
    func testRecentAgentsOpensAndClosesExistingDrawer() {
        let app = launchWorkspaces()
        app.buttons["workspaces.menu"].tap()
        app.buttons["Recent agents"].tap()
        let close = app.buttons["agent-history.close"]
        XCTAssertTrue(close.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.otherElements["agent-history.list"].exists)
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["workspaces.menu"].isHittable)
    }

    @MainActor
    func testRecentWorkspacesClearsSearchAndReturnsToRecentView() {
        let app = launchWorkspaces()
        app.buttons["workspaces.viewMode.Repo"].tap()
        app.buttons["workspaces.search.open"].tap()
        let field = app.textFields["workspaces.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: Self.timeout))
        field.typeText("no-matching-workspace\n")

        app.buttons["workspaces.menu"].tap()
        app.buttons["Recent workspaces"].tap()

        XCTAssertTrue(field.waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["workspaces.viewMode.Recent"].isSelected)
        XCTAssertTrue(app.buttons["workspace.row.demo-ws-dashboard"].exists)
    }

    @MainActor
    private func launchWorkspaces() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data"]
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
}
