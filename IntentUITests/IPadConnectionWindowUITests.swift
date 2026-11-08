import XCTest

/// Picking another connection on iPad reuses the current window; a second
/// window opens only from the row's long-press "Open in New Window" action.
nonisolated final class IPadConnectionWindowUITests: XCTestCase {
    private static let timeout: TimeInterval = 30

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        continueAfterFailure = true
        try super.tearDownWithError()
    }

    @MainActor
    func testSwitchingConnectionReusesWindowAndLongPressOpensNewWindow() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "Multiple windows are an iPad feature")
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-settings", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-appThemePreference", "dark"]
        app.launch()
        XCTAssertTrue(app.buttons["ipad.rail.connections"].waitForExistence(timeout: Self.timeout))
        let initialWindows = app.windows.count

        openConnections(app)
        let travel = card(app, named: "Travel Mac")
        XCTAssertTrue(travel.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(card(app, named: "Studio Mac").label.contains("Connected"))
        capture(name: "IPad-Connections-Before-Switch")
        travel.tap()

        // The switch lands this same window on the Travel Mac workspace list.
        XCTAssertTrue(app.buttons["workspaces.menu"].waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(app.windows.count, initialWindows, app.debugDescription)
        openConnections(app)
        XCTAssertTrue(card(app, named: "Travel Mac").waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(card(app, named: "Travel Mac").label.contains("Connected"), app.debugDescription)
        XCTAssertFalse(card(app, named: "Studio Mac").label.contains("Connected"))
        capture(name: "IPad-Connections-After-Switch")

        card(app, named: "Studio Mac").press(forDuration: 1)
        let newWindow = app.buttons["Open in New Window"]
        XCTAssertTrue(newWindow.waitForExistence(timeout: Self.timeout))
        capture(name: "IPad-Connection-Long-Press-Menu")
        newWindow.tap()
        XCTAssertTrue(newWindow.waitForNonExistence(timeout: Self.timeout))
        // Studio Mac gets its own window; the original window stays on Travel Mac.
        XCTAssertTrue(app.windows.firstMatch.buttons["ipad.rail.workspaces"].wait(for: \.isSelected, toEqual: true, timeout: Self.timeout))
        XCTAssertGreaterThan(app.windows.count, initialWindows, app.debugDescription)
        XCTAssertTrue(card(app, named: "Travel Mac, Connected").exists, app.debugDescription)
        capture(name: "IPad-Connection-After-New-Window")
    }

    @MainActor
    private func openConnections(_ app: XCUIApplication) {
        let rail = app.buttons["ipad.rail.connections"]
        if !rail.isHittable { app.buttons["Show Sidebar"].firstMatch.tap() }
        rail.tap()
    }

    @MainActor
    private func card(_ app: XCUIApplication, named name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "saved-connection.", name)).firstMatch
    }

    @MainActor
    private func capture(name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
