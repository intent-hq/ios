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
        let list = app.descendants(matching: .any).matching(identifier: "workspaces.list").firstMatch
        list.swipeUp()
        let visibleRow = list.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Workspace scroll fixture"))
            .allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(visibleRow)
        let position = visibleRow?.frame.minY ?? 0
        let launcherFrame = app.buttons["intent.menu.open"].frame
        openMenu(app)
        let assistant = app.buttons["intent.menu.assistant"]
        let workspace = app.buttons["intent.menu.workspace"]
        XCTAssertTrue(waitUntilHittable(assistant))
        XCTAssertTrue(waitUntilHittable(workspace))
        XCTAssertLessThan(assistant.frame.minX, workspace.frame.minX)
        let actions = ["assistant", "workspace", "pullRequests", "connections", "appearance", "settings"]
        let viewport = app.scrollViews["intent.menu.tiles"].frame.intersection(app.frame)
        for action in actions {
            let tile = reveal(action, in: app)
            XCTAssertGreaterThanOrEqual(tile.frame.minX, viewport.minX)
            XCTAssertLessThanOrEqual(tile.frame.maxX, viewport.maxX)
        }
        XCTAssertFalse(app.buttons["assistant.actions"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Intent home action tiles"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        if ProcessInfo.processInfo.environment["INTENT_UITEST_VERTICAL_BAR"] == "1" {
            let close = app.buttons["intent.menu.close"]
            XCTAssertTrue(app.frame.contains(close.frame))
            XCTAssertEqual(close.frame.midX, launcherFrame.midX, accuracy: Self.scrollTolerance)
        }
        verifyMenuDragBehavior(in: app)
        app.buttons["intent.menu.close"].tap()
        XCTAssertTrue(app.buttons["intent.menu.open"].appears(timeout: Self.timeout))
        XCTAssertEqual(visibleRow?.frame.minY ?? 0, position, accuracy: Self.scrollTolerance)
        list.swipeDown()
        XCTAssertTrue(app.buttons["workspace.row.demo-ws-reconnect"].isHittable)
    }

    @MainActor
    func testIPadConversationKeepsDraftAndRailAvailable() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad persistent rail")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchHome()
        app.staticTexts["Add usage analytics dashboard"].firstMatch.tap()
        let agent = app.buttons["workspace.agent.demo-agent-implementor"]
        XCTAssertTrue(agent.appears(timeout: Self.timeout))
        agent.tap()
        var composer = app.textViews["composer.textView"]
        XCTAssertTrue(composer.appears(timeout: Self.timeout))
        let rail = app.buttons["ipad.rail.workspaces"]
        let send = app.buttons["Send Message"]
        XCTAssertTrue(rail.isHittable)
        XCTAssertFalse(app.buttons["intent.menu.open"].exists)
        attachScreenshot(XCUIScreen.main.screenshot(), named: "iPad expanded workspace conversation")

        composer.tap()
        let emptyHeight = composer.frame.height
        let draft = Array(repeating: "iPad composer regression", count: 12).joined(separator: " ")
        composer.typeText(draft)
        XCTAssertGreaterThan(composer.frame.height, emptyHeight)
        XCTAssertTrue(send.isEnabled)
        XCTAssertTrue(send.isHittable)
        attachScreenshot(XCUIScreen.main.screenshot(), named: "iPad focused multiline draft")
        XCTAssertFalse(rail.exists, "Focused typing hides background navigation\n\(app.debugDescription)")
        let closeFocus = app.buttons["ipad.focus.close"]
        XCTAssertTrue(closeFocus.isHittable)
        XCTAssertFalse(closeFocus.frame.intersects(send.frame))
        closeFocus.tap()
        XCTAssertTrue(rail.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        XCTAssertEqual(composer.value as? String, draft)
        app.hideWorkspaceSidebar()
        XCTAssertTrue(app.buttons["ipad.sidebar.expand"].appears(timeout: Self.timeout))
        XCTAssertEqual(composer.value as? String, draft)
        attachScreenshot(XCUIScreen.main.screenshot(), named: "iPad collapsed conversation with draft")
        for destination in ["settings", "connections", "workspaces"] {
            app.buttons["ipad.rail.\(destination)"].tap()
            XCTAssertTrue(waitUntilHittable(composer))
            XCTAssertEqual(composer.value as? String, draft)
            XCTAssertTrue(rail.isHittable)
        }
        app.buttons["ipad.rail.assistant"].tap()
        XCTAssertTrue(app.buttons["assistant.sidebar.newConversation"].appears(timeout: Self.timeout))
        app.buttons["ipad.rail.workspaces"].tap()
        composer = try app.textViews.matching(identifier: "composer.textView").singleHittableElement()
        XCTAssertEqual(composer.value as? String, draft)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(try app.buttons.matching(identifier: "Send Message").waitForSingleHittableElement(timeout: Self.timeout).isEnabled)
        XCTAssertEqual(composer.value as? String, draft)
        attachScreenshot(XCUIScreen.main.screenshot(), named: "iPad portrait conversation with draft")
        try verifySendAndBack(in: app, draft: draft)
    }

    @MainActor
    private func verifySendAndBack(in app: XCUIApplication, draft: String) throws {
        try app.buttons.matching(identifier: "Send Message").singleHittableElement().tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", draft))
            .firstMatch.appears(timeout: Self.timeout))
        let composer = try app.textViews.matching(identifier: "composer.textView").singleHittableElement()
        XCTAssertEqual(composer.value as? String, "")
        try app.buttons.matching(identifier: "conversation.back").singleHittableElement().tap()
        let agent = app.buttons["workspace.agent.demo-agent-implementor"]
        XCTAssertTrue(agent.appears(timeout: Self.timeout))
        XCTAssertFalse(app.textViews.matching(identifier: "composer.textView").allElementsBoundByIndex.contains { $0.isHittable })
        XCTAssertTrue(app.buttons["ipad.rail.workspaces"].isHittable)
        XCTAssertTrue(waitUntilHittable(agent))
    }

    @MainActor
    func testIPadQuestionsKeepNextAndRailAvailable() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad persistent rail")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication.intent()
        app.launchArguments += ["--demo-data", "--demo-design-scenario=question-cards"]
        app.launch()
        let workspace = app.staticTexts["Workspace agent design"].firstMatch
        XCTAssertTrue(workspace.appears(timeout: Self.timeout))
        workspace.tap()
        let agent = app.buttons["workspace.agent.demo-agent-design"]
        XCTAssertTrue(agent.appears(timeout: Self.timeout))
        agent.tap()
        XCUIDevice.shared.orientation = .portrait
        let firstAnswer = app.buttons["Keep working locally"]
        XCTAssertTrue(firstAnswer.appears(timeout: Self.timeout))
        firstAnswer.tap()
        let multiAnswer = app.buttons["Local tests"]
        XCTAssertTrue(multiAnswer.appears(timeout: Self.timeout))
        multiAnswer.tap()

        let rail = app.buttons["ipad.rail.workspaces"]
        let next = app.buttons["Next"]
        XCTAssertTrue(waitUntilHittable(next))
        XCTAssertTrue(rail.isHittable)
        XCTAssertFalse(app.textViews["composer.textView"].exists)
        XCTAssertFalse(rail.frame.intersects(next.frame))
        app.buttons["ipad.rail.settings"].tap()
        app.buttons["ipad.rail.workspaces"].tap()
        if app.buttons["ipad.sidebar.dismiss"].exists {
            app.buttons["ipad.sidebar.collapse"].tap()
        }
        XCTAssertTrue(waitUntilHittable(next))
        XCTAssertTrue(next.isEnabled)
        next.tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        let lastAnswer = app.buttons["Summary"]
        XCTAssertTrue(lastAnswer.appears(timeout: Self.timeout))
        lastAnswer.tap()
        let send = app.buttons["Send"]
        XCTAssertTrue(waitUntilHittable(send))
        XCTAssertTrue(send.isEnabled)
        XCTAssertFalse(rail.frame.intersects(send.frame))
        attachScreenshot(XCUIScreen.main.screenshot(), named: "iPad question actions beside persistent rail")
        XCTAssertTrue(waitUntilHittable(send))
        send.tap()

        let composer = app.textViews["composer.textView"]
        XCTAssertTrue(composer.appears(timeout: Self.timeout))
        XCTAssertTrue(rail.isHittable)
        XCTAssertTrue(waitUntilHittable(composer))
    }

    @MainActor
    func testConnectionsTileOpensScreenAndAppearanceTileCyclesTheme() throws {
        let app = launchHome(themePreference: "dark")
        openMenu(app)
        XCTAssertEqual(reveal("appearance", in: app).value as? String, "Dark Mode")
        reveal("appearance", in: app).tap()
        _ = reveal("settings", in: app)
        reveal("connections", in: app).tap()
        XCTAssertTrue(app.staticTexts["saved-connections.title"].appears(timeout: Self.timeout))
        app.terminate()
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
}

extension HomeActionMenuUITests {
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
        _ = reveal("connections", in: app)
    }

    @MainActor
    private func launchHome(themePreference: String = "system") -> XCUIApplication {
        let app = XCUIApplication.intent()
        app.launchArguments += ["--demo-data", "--demo-long-workspace-list", "-appThemePreference", themePreference]
        app.launch()
        let navigation = UIDevice.current.userInterfaceIdiom == .pad ? "ipad.rail.workspaces" : "intent.menu.open"
        XCTAssertTrue(app.buttons[navigation].appears(timeout: Self.timeout))
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
        XCTAssertTrue(app.buttons["intent.menu.assistant"].appears(timeout: Self.timeout))
    }

    @MainActor
    private func reveal(_ action: String, in app: XCUIApplication) -> XCUIElement {
        app.revealHomeAction(action)
    }
}

extension HomeActionMenuUITests {
    @MainActor
    func testDuoWorkspaceDetailKeepsOnlyTheAccessibleContentTitle() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["INTENT_UITEST_FOLDED_DUO"] == "1" || environment["INTENT_UITEST_UNFOLDED_DUO"] == "1",
            "Requires a user-configured Duo; this test never changes display mode"
        )
        let app = launchHome(themePreference: "light")
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(waitUntilHittable(workspace))
        workspace.tap()
        let heading = app.staticTexts["workspace.title.heading"]
        XCTAssertTrue(waitUntilHittable(heading))
        XCTAssertEqual(heading.label, "Add usage analytics dashboard")
        XCTAssertEqual(app.navigationBars.staticTexts.count, 0, "Duo must not repeat the workspace title above the content")
        if environment["INTENT_UITEST_UNFOLDED_DUO"] != "1" {
            XCTAssertEqual(app.scrollViews["workspace.detail.scroll"].frame.minY, app.windows.firstMatch.frame.minY, accuracy: 1)
        }
        let actions = app.buttons["Workspace actions"]
        XCTAssertTrue(waitUntilHittable(actions))
        XCTAssertGreaterThan(actions.frame.minX, heading.frame.maxX)
        XCTAssertEqual(app.buttons["workspaceDetail.back"].exists, environment["INTENT_UITEST_FOLDED_DUO"] == "1")
        attachScreenshot(app.screenshot(), named: "Duo workspace detail without header")
    }

    @MainActor
    func testFoldedDuoLauncherStaysInRailAcrossDetailNavigation() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["INTENT_UITEST_FOLDED_DUO"] == "1",
            "Requires a user-configured folded Duo; this test never changes display mode"
        )
        let app = launchHome(themePreference: "light")
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(waitUntilHittable(workspace))
        workspace.tap()
        let back = app.buttons["workspaceDetail.back"]
        let rootActions = app.buttons["Workspace actions"]
        XCTAssertTrue(waitUntilHittable(rootActions))
        XCTAssertTrue(waitUntilHittable(back))
        back.tap()
        XCTAssertTrue(waitUntilHittable(app.buttons["workspaces.search.open"]))
        workspace.tap()
        XCTAssertTrue(waitUntilHittable(back))
        let launcher = app.buttons["intent.menu.open"]
        XCTAssertTrue(waitUntilHittable(launcher))
        XCTAssertEqual(app.buttons.matching(identifier: "intent.menu.open").count, 1)
        XCTAssertEqual(launcher.frame.midX, rootActions.frame.midX, accuracy: Self.scrollTolerance)
        XCTAssertLessThan(rootActions.frame.maxY, app.frame.midY)
        XCTAssertGreaterThan(launcher.frame.minY, app.frame.midY)
        app.buttons["Changes"].firstMatch.tap()
        let file = app.buttons["changes.file.unstaged.Sources/Analytics.swift"].firstMatch
        XCTAssertTrue(waitUntilHittable(file))
        XCTAssertGreaterThan(launcher.frame.minX, file.frame.maxX)
        attachScreenshot(app.screenshot(), named: "Folded Duo Changes launcher rail")
        openMenu(app)
        app.buttons["intent.menu.close"].tap()
        XCTAssertTrue(app.buttons["intent.menu.close"].disappears(timeout: Self.timeout))
        app.buttons["Agents"].firstMatch.tap()
        let agent = app.buttons["workspace.agent.demo-agent-implementor"]
        XCTAssertTrue(waitUntilHittable(agent))
        agent.tap()
        let composer = app.textViews["composer.textView"]
        XCTAssertTrue(waitUntilHittable(composer))
        let conversationBack = app.buttons["conversation.back"]
        XCTAssertTrue(waitUntilHittable(conversationBack))
        XCTAssertTrue(waitUntilHittable(launcher))
        XCTAssertEqual(launcher.frame.midX, conversationBack.frame.midX, accuracy: Self.scrollTolerance)
        XCTAssertGreaterThan(launcher.frame.minX, composer.frame.maxX)
        conversationBack.tap()
        XCTAssertTrue(waitUntilHittable(agent))
        XCTAssertTrue(waitUntilHittable(launcher))
        XCTAssertTrue(waitUntilHittable(back))
        XCTAssertEqual(launcher.frame.midX, rootActions.frame.midX, accuracy: Self.scrollTolerance)
    }

    @MainActor
    func testUnfoldedDuoKeepsSharedSidebarAndDetailNavigation() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["INTENT_UITEST_UNFOLDED_DUO"] == "1",
            "Requires a user-configured unfolded Duo; this test never changes display mode"
        )
        let app = launchHome(themePreference: "light")
        let window = app.windows.firstMatch
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(waitUntilHittable(workspace))
        workspace.tap()
        let agent = app.buttons["workspace.agent.demo-agent-implementor"]
        XCTAssertTrue(waitUntilHittable(agent))
        XCTAssertFalse(app.buttons["workspaceDetail.back"].exists)
        let sidebar = app.descendants(matching: .any).matching(identifier: "workspaces.list").firstMatch
        XCTAssertLessThanOrEqual(sidebar.frame.maxX, agent.frame.minX)
        XCTAssertTrue(workspace.isHittable)
        let rootActions = app.buttons["Workspace actions"]
        XCTAssertTrue(waitUntilHittable(rootActions))
        XCTAssertLessThan(rootActions.frame.maxY, window.frame.midY)
        XCTAssertFalse(app.buttons["ipad.rail.workspaces"].exists, "The unfolded Duo replaces the global rail with its launcher")
        XCTAssertTrue(app.buttons["intent.menu.open"].isHittable)
        attachScreenshot(app.screenshot(), named: "Unfolded Duo workspace split")

        let sidebarFrame = sidebar.frame
        agent.tap()
        let composer = app.textViews["composer.textView"]
        XCTAssertTrue(waitUntilHittable(composer))
        let back = app.buttons["conversation.back"]
        let actions = app.buttons["conversation.actions.open"]
        XCTAssertTrue(waitUntilHittable(back))
        XCTAssertTrue(actions.isHittable)
        XCTAssertTrue(agent.wait(for: \.isSelected, toEqual: true, timeout: Self.timeout))
        XCTAssertLessThanOrEqual(agent.frame.maxX, composer.frame.minX)
        XCTAssertEqual(back.frame.midY, actions.frame.midY, accuracy: Self.scrollTolerance)
        XCTAssertLessThan(actions.frame.maxY, window.frame.midY)
        XCTAssertFalse(app.buttons["ipad.rail.workspaces"].exists)
        XCTAssertTrue(app.buttons["intent.menu.open"].isHittable)
        attachScreenshot(app.screenshot(), named: "Unfolded Duo conversation split")
        back.tap()
        XCTAssertTrue(waitUntilHittable(agent))
        XCTAssertTrue(composer.disappears(timeout: Self.timeout))
        XCTAssertTrue(workspace.isHittable)
        XCTAssertEqual(sidebar.frame, sidebarFrame)
        XCTAssertFalse(app.buttons["workspaceDetail.back"].exists)
        attachScreenshot(app.screenshot(), named: "Unfolded Duo after back")
    }
}
