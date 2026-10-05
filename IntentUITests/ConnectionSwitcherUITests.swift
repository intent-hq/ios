import XCTest

nonisolated final class ConnectionSwitcherUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        continueAfterFailure = true
        try super.tearDownWithError()
    }

    @MainActor
    func testEdgeRevealSwitchesTheWindowAndCurrentSelectionOnlyCloses() throws {
        let app = try launch()
        reveal(app)
        let studio = connection("Studio Mac", in: app)
        let travel = connection("Travel Mac", in: app)
        XCTAssertTrue(studio.isSelected)
        XCTAssertFalse(travel.isSelected)
        capture(app, name: "Connection-Switcher-Dark")
        studio.tap()
        assertClosed(app)

        reveal(app)
        travel.tap()
        assertClosed(app)
        reveal(app)
        XCTAssertTrue(connection("Travel Mac", in: app).isSelected)
        XCTAssertFalse(connection("Studio Mac", in: app).isSelected)
        app.buttons["connection-switcher.close"].tap()
        assertClosed(app)
    }

    @MainActor
    func testCancelledAndNonEdgeDragsPreserveThePageAndReverseSwipeCloses() throws {
        let app = try launch()
        drag(app, from: CGVector(dx: 0.005, dy: 0.5), to: CGVector(dx: 0.15, dy: 0.5))
        assertClosed(app)
        drag(app, from: CGVector(dx: 0.35, dy: 0.5), to: CGVector(dx: 0.85, dy: 0.5))
        assertClosed(app)
        // Reopening and closing must refresh the gate in both directions.
        for _ in 0..<2 {
            reveal(app)
            drag(app, from: CGVector(dx: 0.9, dy: 0.5), to: CGVector(dx: 0.1, dy: 0.5))
            assertClosed(app)
            drag(app, from: CGVector(dx: 0.35, dy: 0.5), to: CGVector(dx: 0.85, dy: 0.5))
            assertClosed(app)
        }
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(workspace.isHittable)
        workspace.tap()
        XCTAssertTrue(app.buttons["workspace.agent.demo-agent-implementor"].waitForExistence(timeout: Self.timeout))
        drag(app, from: CGVector(dx: 0.005, dy: 0.5), to: CGVector(dx: 0.85, dy: 0.5))
        assertClosed(app)
    }

    @MainActor
    func testEdgeRevealClosesRowActionsAndKeepsRowSwipesAvailable() throws {
        let app = try launch()
        let row = app.buttons["workspace.row.demo-ws-dashboard"]
        let archive = app.buttons["workspace.archive.demo-ws-dashboard"]
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        let end = start.withOffset(CGVector(dx: -180, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(archive.waitForExistence(timeout: Self.timeout))

        let edge = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 2, dy: row.frame.midY))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: 300, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(app.buttons["connection-switcher.close"].waitForExistence(timeout: Self.timeout))
        app.buttons["connection-switcher.close"].tap()
        assertClosed(app)
        XCTAssertFalse(archive.exists)

        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(archive.waitForExistence(timeout: Self.timeout))
        archive.tap()
        let confirmation = app.alerts["Archive Workspace"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: Self.timeout))
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(row.exists)
    }

    @MainActor
    func testLargeTextAndLightAppearanceKeepConnectionsReachable() throws {
        let app = try launch(largeText: true)
        reveal(app)
        let travel = connection("Travel Mac", in: app)
        if !travel.isHittable { app.scrollViews["connection-switcher.list"].swipeUp() }
        XCTAssertTrue(travel.isHittable)
        capture(app, name: "Connection-Switcher-Large-Text-Light")
        travel.tap()
        assertClosed(app)
        reveal(app)
        XCTAssertTrue(connection("Travel Mac", in: app).isSelected)
    }

    @MainActor
    private func launch(largeText: Bool = false) throws -> XCUIApplication {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "The connection underlay is on the compact Workspaces page")
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-settings", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-appThemePreference", largeText ? "light" : "dark"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.buttons["workspaces.search.open"].waitForExistence(timeout: Self.timeout))
        return app
    }

    @MainActor
    private func reveal(_ app: XCUIApplication) {
        drag(app, from: CGVector(dx: 0.005, dy: 0.5), to: CGVector(dx: 0.85, dy: 0.5))
        XCTAssertTrue(app.buttons["connection-switcher.close"].waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(connection("Studio Mac", in: app).exists)
    }

    @MainActor
    private func assertClosed(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["connection-switcher.close"].waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["workspaces.search.open"].waitForExistence(timeout: Self.timeout))
    }

    @MainActor
    private func connection(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "connection-switcher.connection.", name)).firstMatch
    }

    @MainActor
    private func drag(_ app: XCUIApplication, from start: CGVector, to end: CGVector) {
        app.coordinate(withNormalizedOffset: start).press(
            forDuration: 0.05,
            thenDragTo: app.coordinate(withNormalizedOffset: end),
            withVelocity: .slow,
            thenHoldForDuration: 0.5
        )
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
