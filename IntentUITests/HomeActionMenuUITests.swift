import XCTest

nonisolated final class HomeActionMenuUITests: XCTestCase {
    private static let timeout: TimeInterval = 30
    private static let scrollTolerance: CGFloat = 4
    private static let backdropStartY: CGFloat = 0.2
    private static let backdropEndY: CGFloat = 0.4
    private static let composerBottomTolerance: CGFloat = 60

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
    func testMenuPlacementSurvivesDrawerRoundTrips() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Compact workspace page drawers")
        // Opt in only when the selected simulator is in a vertical-bar display mode.
        let expectsVerticalBar = ProcessInfo.processInfo.environment["INTENT_UITEST_VERTICAL_BAR"] == "1"
        let app = launchHome(themePreference: "light")
        let launcher = app.buttons["intent.menu.open"]
        XCTAssertTrue(waitUntilHittable(launcher))
        XCTAssertEqual(app.buttons.matching(identifier: "intent.menu.open").count, 1)
        let originalFrame = launcher.frame
        if expectsVerticalBar {
            XCTAssertGreaterThan(originalFrame.minX, app.buttons["workspaces.search.open"].frame.maxX)
            XCTAssertEqual(originalFrame.width, 48, accuracy: 1)
            XCTAssertEqual(originalFrame.height, 48, accuracy: 1)
        } else {
            XCTAssertEqual(originalFrame.width, 80, accuracy: 1)
            XCTAssertLessThanOrEqual(originalFrame.maxX, app.scrollViews["workspaces.list"].frame.maxX)
        }
        attachScreenshot(app.screenshot(), named: "Intent menu placement closed")
        openMenu(app)
        XCTAssertTrue(waitUntilHittable(app.buttons["intent.menu.close"]))
        XCTAssertTrue(app.buttons["intent.menu.assistant"].isHittable)
        XCTAssertTrue(app.frame.contains(app.buttons["intent.menu.close"].frame))
        attachScreenshot(app.screenshot(), named: "Intent menu placement open")
        app.buttons["intent.menu.close"].tap()
        XCTAssertTrue(app.buttons["intent.menu.close"].waitForNonExistence(timeout: Self.timeout))
        for (title, closeId) in [
            ("Recent connections", "connection-switcher.close"),
            ("Recent agents", "agent-history.close")
        ] {
            XCTAssertTrue(waitUntilHittable(app.buttons["workspaces.menu"]))
            app.buttons["workspaces.menu"].tap()
            let action = app.buttons[title]
            XCTAssertTrue(action.waitForExistence(timeout: Self.timeout))
            action.tap()
            let close = app.buttons[closeId]
            XCTAssertTrue(waitUntilHittable(close))
            XCTAssertFalse(app.buttons["workspace.row.demo-ws-dashboard"].isHittable)
            attachScreenshot(app.screenshot(), named: "Intent menu placement \(title)")
            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: Self.timeout))
            XCTAssertTrue(waitUntilHittable(launcher))
            XCTAssertEqual(launcher.frame.minX, originalFrame.minX, accuracy: 1)
            XCTAssertEqual(launcher.frame.minY, originalFrame.minY, accuracy: 1)
            openMenu(app)
            app.buttons["intent.menu.close"].tap()
            XCTAssertTrue(app.buttons["intent.menu.close"].waitForNonExistence(timeout: Self.timeout))
        }
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
        XCTAssertLessThan(launcher.frame.maxY, composer.frame.minY)
        XCTAssertLessThan(app.frame.maxY - composer.frame.maxY, Self.composerBottomTolerance)
        let launcherBottom = launcher.frame.maxY
        openMenu(app)
        XCTAssertEqual(app.buttons["intent.menu.close"].frame.maxY, launcherBottom, accuracy: Self.scrollTolerance)
        attachScreenshot(XCUIScreen.main.screenshot(), named: "iPad landscape Intent menu tiles")
        app.buttons["intent.menu.close"].tap()
        XCTAssertTrue(waitUntilHittable(composer))

        composer.tap()
        let emptyHeight = composer.frame.height
        let draft = Array(repeating: "iPad composer regression", count: 12).joined(separator: " ")
        composer.typeText(draft)
        XCTAssertGreaterThan(composer.frame.height, emptyHeight)
        XCTAssertTrue(send.isEnabled)
        XCTAssertTrue(send.isHittable)
        XCTAssertFalse(launcher.frame.intersects(send.frame))
        XCTAssertLessThan(launcher.frame.maxY, composer.frame.minY)
        attachScreenshot(XCUIScreen.main.screenshot(), named: "iPad Intent menu floating above the composer")
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
        XCTAssertGreaterThan(launcher.frame.maxY, app.frame.maxY - Self.composerBottomTolerance)
        openMenu(app)
        app.buttons["intent.menu.close"].tap()
        XCTAssertTrue(waitUntilHittable(agent))
    }

    @MainActor
    func testIPadQuestionsKeepNextAndSendAvailable() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad window-level menu")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-design-scenario=question-cards"]
        app.launch()
        let workspace = app.staticTexts["Workspace agent design"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
        workspace.tap()
        let agent = app.buttons["workspace.agent.demo-agent-design"]
        XCTAssertTrue(agent.waitForExistence(timeout: Self.timeout))
        agent.tap()
        XCUIDevice.shared.orientation = .portrait
        let firstAnswer = app.buttons["Keep working locally"]
        XCTAssertTrue(firstAnswer.waitForExistence(timeout: Self.timeout))
        firstAnswer.tap()
        let multiAnswer = app.buttons["Local tests"]
        XCTAssertTrue(multiAnswer.waitForExistence(timeout: Self.timeout))
        multiAnswer.tap()

        let launcher = app.buttons["intent.menu.open"]
        let next = app.buttons["Next"]
        XCTAssertTrue(waitUntilHittable(next))
        XCTAssertTrue(launcher.isHittable)
        XCTAssertFalse(app.textViews["composer.textView"].exists)
        XCTAssertFalse(launcher.frame.intersects(next.frame))
        XCTAssertLessThan(launcher.frame.maxY, next.frame.minY)
        next.tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        let lastAnswer = app.buttons["Summary"]
        XCTAssertTrue(lastAnswer.waitForExistence(timeout: Self.timeout))
        lastAnswer.tap()
        let send = app.buttons["Send"]
        XCTAssertTrue(waitUntilHittable(send))
        XCTAssertTrue(send.isEnabled)
        XCTAssertFalse(launcher.frame.intersects(send.frame))
        XCTAssertLessThan(launcher.frame.maxY, send.frame.minY)
        openMenu(app)
        app.buttons["intent.menu.close"].tap()
        XCTAssertTrue(waitUntilHittable(send))
        send.tap()

        let composer = app.textViews["composer.textView"]
        XCTAssertTrue(composer.waitForExistence(timeout: Self.timeout))
        XCTAssertLessThan(launcher.frame.maxY, composer.frame.minY)
        XCTAssertLessThan(app.frame.maxY - composer.frame.maxY, Self.composerBottomTolerance)
    }

    @MainActor
    func testConnectionsTileOpensScreenAndAppearanceTileCyclesTheme() throws {
        let app = launchHome(themePreference: "dark")
        openMenu(app)
        // Seed stored System through the Home tile before removing the launch override.
        XCTAssertEqual(reveal("appearance", in: app).value as? String, "Dark Mode")
        reveal("appearance", in: app).tap()
        // Connections is then behind us, so the helper must also scroll back toward the start.
        _ = reveal("settings", in: app)
        reveal("connections", in: app).tap()
        XCTAssertTrue(app.staticTexts["saved-connections.title"].waitForExistence(timeout: Self.timeout))
        // Relaunch restores the home screen without depending on the connection sheet's detent.
        app.terminate()
        // Argument-domain overrides mask later writes, so remove it before exercising live changes.
        app.launchArguments = ["--demo-data", "--demo-long-workspace-list"]
        app.launch()
        openMenu(app)
        let appearance = reveal("appearance", in: app)
        XCTAssertEqual(appearance.value as? String, "System")
        let systemIsDark = try app.renderedHomeActionIsDark("appearance")
        for mode in ["Light Mode", "Dark Mode", "System", "Light Mode", "Dark Mode", "System", "Light Mode"] {
            appearance.tap()
            let updated = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", mode), object: appearance
            )
            XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: Self.timeout), .completed)
            XCTAssertEqual(appearance.label, "Appearance")
            XCTAssertTrue(app.scrollViews["intent.menu.tiles"].exists)
            XCTAssertTrue(app.buttons["intent.menu.close"].isHittable)
            XCTAssertFalse(app.navigationBars["Appearance"].exists)
            XCTAssertEqual(
                try app.renderedHomeActionIsDark("appearance"),
                mode == "System" ? systemIsDark : mode == "Dark Mode",
                "The rendered app must follow \(mode) on every tap, not just update the tile label"
            )
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Appearance tile - \(mode)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        app.terminate()
        app.launch()
        openMenu(app)
        XCTAssertEqual(reveal("appearance", in: app).value as? String, "Light Mode")
        XCTAssertFalse(try app.renderedHomeActionIsDark("appearance"))
    }

    @MainActor
    func testUnknownAppearanceCyclesFromSystemToLight() {
        let app = launchHome(themePreference: "legacy")
        openMenu(app)
        let appearance = reveal("appearance", in: app)
        XCTAssertEqual(appearance.value as? String, "System")
        appearance.tap()
        XCTAssertTrue(app.scrollViews["intent.menu.tiles"].exists)
        app.terminate()
        // Read the new stored value without the legacy launch override masking it.
        app.launchArguments = ["--demo-data", "--demo-long-workspace-list"]
        app.launch()
        openMenu(app)
        XCTAssertEqual(reveal("appearance", in: app).value as? String, "Light Mode")
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
    private func launchHome(themePreference: String = "system") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-long-workspace-list", "-appThemePreference", themePreference]
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
    private func attachScreenshot(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
