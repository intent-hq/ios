import XCTest

nonisolated final class WorkspaceListMenuUITests: XCTestCase {
    private static let timeout: TimeInterval = 15
    private static let maximumHistorySwipes = 12

    @MainActor
    func testEmptyWorkspaceButtonOpensCreationAndReturns() {
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        defer { XCUIDevice.shared.orientation = .portrait }
        for appearance in ["light", "dark"] {
            let app = launchWorkspaces(arguments: ["--demo-empty-workspaces", "-appThemePreference", appearance])
            let create = app.buttons["workspaces.empty.create"]
            XCTAssertTrue(create.appears(timeout: Self.timeout))
            XCTAssertTrue(create.isEnabled)
            capture(app, named: "empty-workspaces-\(appearance)")
            XCTAssertTrue(create.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
            create.tap()
            closeCreation(in: app)
            XCTAssertTrue(create.appears(timeout: Self.timeout))
            app.buttons["workspaces.search.open"].tap()
            let search = app.textFields["workspaces.search.field"]
            XCTAssertTrue(search.appears(timeout: Self.timeout))
            search.typeText("no-matching-workspace")
            XCTAssertTrue(create.disappears(timeout: Self.timeout))
            app.buttons["workspaces.search.cancel"].tap()
            XCTAssertTrue(create.appears(timeout: Self.timeout))
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
            XCTAssertTrue(workspace.appears(timeout: Self.timeout))
            XCTAssertFalse(app.buttons["workspaces.empty.create"].exists)
            app.buttons["workspaces.menu"].tap()
            let create = app.buttons["workspaces.menu.create"]
            XCTAssertTrue(create.appears(timeout: Self.timeout))
            XCTAssertTrue(create.isEnabled)
            capture(app, named: "new-workspace-menu-\(appearance)")
            create.tap()
            closeCreation(in: app)
            XCTAssertTrue(workspace.appears(timeout: Self.timeout))
            XCTAssertTrue(app.buttons["workspaces.menu"].isHittable)
            if UIDevice.current.userInterfaceIdiom == .pad {
                let railCreate = app.buttons["ipad.rail.createWorkspace"]
                XCTAssertTrue(railCreate.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
                railCreate.tap()
                closeCreation(in: app)
                XCTAssertTrue(workspace.appears(timeout: Self.timeout))
            }
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
        XCTAssertTrue(close.appears(timeout: Self.timeout))
        let heading = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Recent agents")).firstMatch
        XCTAssertTrue(heading.appears(timeout: Self.timeout))
        XCTAssertTrue(heading.isHittable)
        capture(app, named: "workspace-menu-recent-agents")
        close.tap()
        XCTAssertTrue(close.disappears(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["workspaces.menu"].isHittable)
    }

    @MainActor
    func testRecentAgentsScrollsToLastEntryAndOpensAgent() {
        for appearance in ["light", "dark"] {
            let app = launchWorkspaces(arguments: ["--demo-long-agent-history", "-appThemePreference", appearance])
            app.buttons["workspaces.menu"].tap()
            app.buttons["Recent agents"].tap()
            let list = app.scrollViews["agent-history.list"]
            XCTAssertTrue(list.appears(timeout: Self.timeout))
            let last = list.buttons.matching(NSPredicate(format: "identifier ENDSWITH %@", "/demo-agent-deflake")).firstMatch
            capture(app, named: "recent-agents-top-\(appearance)")
            for _ in 0..<Self.maximumHistorySwipes {
                if last.exists, list.frame.contains(last.frame), last.isHittable { break }
                list.swipeUp()
            }
            XCTAssertTrue(last.isHittable, "The final history entry must be reachable by scrolling")
            XCTAssertTrue(list.frame.contains(last.frame), "The final history entry must be fully visible")
            capture(app, named: "recent-agents-bottom-\(appearance)")
            last.tap()
            XCTAssertTrue(app.buttons["agent-history.close"].disappears(timeout: Self.timeout))
            XCTAssertTrue(app.textViews["composer.textView"].appears(timeout: Self.timeout))
            app.terminate()
        }
    }

    @MainActor
    func testRecentConnectionsOpensSwitcherAndSelectsConnection() {
        let app = launchWorkspaces()
        app.buttons["workspaces.viewMode.Repo"].tap()
        app.buttons["workspaces.menu"].tap()
        app.buttons["Recent connections"].tap()
        let close = app.buttons["connection-switcher.close"]
        XCTAssertTrue(close.appears(timeout: Self.timeout))
        let studio = connection("Studio Mac", in: app)
        let travel = connection("Travel Mac", in: app)
        XCTAssertTrue(studio.isSelected)
        XCTAssertTrue(travel.isHittable)
        capture(app, named: "workspace-menu-recent-connections")
        studio.tap()
        XCTAssertTrue(close.disappears(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["workspaces.viewMode.Repo"].isSelected)

        app.buttons["workspaces.menu"].tap()
        app.buttons["Recent connections"].tap()
        travel.tap()
        XCTAssertTrue(close.disappears(timeout: Self.timeout))
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
        XCTAssertTrue(activeClose.disappears(timeout: Self.timeout))
    }

    @MainActor
    private func launchWorkspaces(arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication.intent()
        app.launchArguments += ["--demo-data", "--demo-settings", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += arguments
        app.launch()
        let menu = app.buttons["workspaces.menu"]
        if UIDevice.current.userInterfaceIdiom == .pad, !menu.appears(timeout: 2) {
            let showSidebar = app.buttons["Show Sidebar"]
            XCTAssertTrue(showSidebar.appears(timeout: Self.timeout))
            showSidebar.tap()
        }
        XCTAssertTrue(menu.appears(timeout: Self.timeout))
        let allowNotifications = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allowNotifications.appears(timeout: 2) { allowNotifications.tap() }
        return app
    }

    @MainActor
    private func closeCreation(in app: XCUIApplication) {
        let title = app.staticTexts["creation.repositoryTitle"]
        XCTAssertTrue(title.appears(timeout: Self.timeout))
        app.buttons["creation.close"].tap()
        XCTAssertTrue(title.disappears(timeout: Self.timeout))
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
