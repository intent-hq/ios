import XCTest

nonisolated final class HomeActionMenuUITests: XCTestCase {
    private static let timeout: TimeInterval = 30
    private static let scrollTolerance: CGFloat = 4
    private static let backdropStartY: CGFloat = 0.2
    private static let backdropEndY: CGFloat = 0.4

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        continueAfterFailure = true
        try super.tearDownWithError()
    }

    @MainActor
    func testClosePreservesWorkspaceScrollAndAssistantIsFirst() {
        let app = launchHome()
        let list = app.scrollViews["workspaces.list"]
        list.swipeUp()
        let visibleRow = list.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Workspace scroll fixture"))
            .allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(visibleRow)
        let position = visibleRow?.frame.minY ?? 0
        openMenu(app)
        let assistant = app.buttons["intent.menu.assistant"]
        let workspace = app.buttons["intent.menu.workspace"]
        XCTAssertTrue(assistant.isHittable)
        XCTAssertTrue(workspace.isHittable)
        XCTAssertLessThan(assistant.frame.minX, workspace.frame.minX)
        XCTAssertFalse(app.buttons["assistant.actions"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Intent home action tiles"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        verifyMenuDragBehavior(in: app)
        app.buttons["intent.menu.close"].tap()
        XCTAssertTrue(app.buttons["intent.menu.open"].waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(visibleRow?.frame.minY ?? 0, position, accuracy: Self.scrollTolerance)
        list.swipeDown()
        XCTAssertTrue(app.staticTexts["workspaces.title"].isHittable)
    }

    @MainActor
    func testIPadConversationKeepsSendAndMenuAvailable() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad window-level menu")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchHome()
        app.staticTexts["Add usage analytics dashboard"].firstMatch.tap()
        let agent = app.buttons["workspace.agent.demo-agent-implementor"]
        XCTAssertTrue(agent.waitForExistence(timeout: Self.timeout))
        agent.tap()
        let composer = app.textViews["composer.textView"]
        XCTAssertTrue(composer.waitForExistence(timeout: Self.timeout))
        let launcher = app.buttons["intent.menu.open"]
        let send = app.buttons["Send message"]
        XCTAssertTrue(launcher.isHittable)
        XCTAssertFalse(launcher.frame.intersects(send.frame))

        composer.tap()
        let draft = "iPad composer regression"
        composer.typeText(draft)
        XCTAssertTrue(send.isEnabled)
        XCTAssertTrue(send.isHittable)
        XCTAssertFalse(launcher.frame.intersects(send.frame))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "iPad conversation composer and menu with reserved space"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        send.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", draft))
            .firstMatch.waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(composer.value as? String, "")
        XCTAssertFalse(app.buttons["intent.menu.close"].exists)
        openMenu(app)
        app.buttons["intent.menu.close"].tap()
        XCTAssertTrue(waitUntilHittable(composer))

        app.navigationBars["Dashboard Implementor"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(agent.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(composer.waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(launcher.isHittable)
        openMenu(app)
        app.buttons["intent.menu.close"].tap()
        XCTAssertTrue(waitUntilHittable(agent))
    }

    @MainActor
    func testConnectionsAndAppearanceTilesOpenTheirScreens() {
        let app = launchHome()
        openMenu(app)
        reveal("connections", in: app).tap()
        XCTAssertTrue(app.staticTexts["saved-connections.title"].waitForExistence(timeout: Self.timeout))
        // Relaunch restores the home screen without depending on the connection sheet's detent.
        app.terminate()
        app.launch()
        openMenu(app)
        reveal("appearance", in: app).tap()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["System"].exists || app.staticTexts["System"].exists)
        app.navigationBars["Appearance"].buttons["Done"].tap()
        XCTAssertTrue(app.buttons["intent.menu.open"].waitForExistence(timeout: Self.timeout))
    }

    @MainActor
    func testWorkspaceAndLogsTilesOpenTheirDestinations() {
        let app = launchHome()
        openMenu(app)
        app.buttons["intent.menu.workspace"].tap()
        XCTAssertTrue(app.navigationBars["Select Repository"].waitForExistence(timeout: Self.timeout))
        app.terminate()
        app.launch()
        openMenu(app)
        reveal("acknowledgements", in: app).tap()
        XCTAssertTrue(app.navigationBars["Acks & Logs"].waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["Acknowledgements"].exists)
        app.buttons["Export logs"].tap()
        XCTAssertTrue(app.navigationBars["Export logs"].waitForExistence(timeout: Self.timeout))
    }

    @MainActor
    func testLogOffRequiresConfirmationAndCanBeCancelled() {
        let app = launchHome()
        openMenu(app)
        reveal("logOff", in: app).tap()
        let confirmation = app.alerts["Log Off?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: Self.timeout))
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["intent.menu.close"].isHittable)
        app.buttons["intent.menu.close"].tap()
        XCTAssertTrue(app.buttons["intent.menu.open"].waitForExistence(timeout: Self.timeout))
    }

    @MainActor
    private func verifyMenuDragBehavior(in app: XCUIApplication) {
        let carousel = app.scrollViews["intent.menu.tiles"]
        let assistant = app.buttons["intent.menu.assistant"]
        let position = assistant.frame.minY
        carousel.swipeUp()
        XCTAssertTrue(assistant.exists, "A vertical drag must not open a tile's destination")
        XCTAssertEqual(assistant.frame.minY, position, accuracy: Self.scrollTolerance)
        carousel.swipeDown()
        XCTAssertTrue(assistant.exists, "A vertical drag must keep the menu open")
        XCTAssertEqual(assistant.frame.minY, position, accuracy: Self.scrollTolerance)
        let backdropStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: Self.backdropStartY))
        let backdropEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: Self.backdropEndY))
        backdropStart.press(forDuration: 0, thenDragTo: backdropEnd)
        backdropEnd.press(forDuration: 0, thenDragTo: backdropStart)
        XCTAssertTrue(app.buttons["intent.menu.close"].isHittable)
        XCTAssertEqual(reveal("connections", in: app).frame.minY, position, accuracy: Self.scrollTolerance)
    }

    @MainActor
    private func launchHome() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-long-workspace-list"]
        app.launch()
        XCTAssertTrue(app.buttons["intent.menu.open"].waitForExistence(timeout: Self.timeout))
        return app
    }

    @MainActor
    private func waitUntilHittable(_ element: XCUIElement) -> Bool {
        let available = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"), object: element
        )
        return XCTWaiter.wait(for: [available], timeout: Self.timeout) == .completed
    }

    @MainActor
    private func openMenu(_ app: XCUIApplication) {
        app.buttons["intent.menu.open"].tap()
        XCTAssertTrue(app.buttons["intent.menu.assistant"].waitForExistence(timeout: Self.timeout))
    }

    @MainActor
    private func reveal(_ action: String, in app: XCUIApplication) -> XCUIElement {
        app.revealHomeAction(action)
    }
}
