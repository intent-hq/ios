import XCTest

nonisolated final class IPadToolPlacementUITests: XCTestCase {
    private static let timeout: TimeInterval = 20

    @MainActor
    func testBrowserDragKeepsChatDraftAndRestoresMainChatInBothThemes() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad tool placement")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            let agent = app.buttons["workspace.agent.demo-agent-implementor"]
            XCTAssertTrue(agent.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
            agent.tap()
            let composer = app.textViews["composer.textView"]
            XCTAssertTrue(composer.waitForExistence(timeout: Self.timeout))
            composer.tap()
            composer.typeText("Keep this draft beside the preview")
            app.buttons["ipad.focus.close"].tap()
            let browser = app.buttons["browser.row.tab:demo-agent-browser"]
            reveal(browser, in: app)
            capture(app, "ipad-tool-before-\(appearance)")
            drag(browser, into: app)
            let close = app.buttons["Close main browser"]
            XCTAssertTrue(close.waitForExistence(timeout: Self.timeout))
            XCTAssertTrue(composer.waitForExistence(timeout: Self.timeout))
            XCTAssertEqual(composer.value as? String, "Keep this draft beside the preview")
            XCTAssertLessThan(composer.frame.maxX, close.frame.minX)
            capture(app, "ipad-tool-browser-chat-\(appearance)")
            composer.tap()
            composer.typeText(" with chat")
            let editedDraft = composer.value as? String
            XCTAssertEqual(editedDraft?.contains(" with chat"), true)
            XCTAssertEqual(editedDraft?.replacingOccurrences(of: " with chat", with: ""), "Keep this draft beside the preview")
            XCTAssertFalse(app.buttons["ipad.focus.close"].exists)
            XCTAssertLessThan(composer.frame.maxX, close.frame.minX)
            app.buttons["conversation.back"].tap()
            reveal(agent, in: app, scrollingUp: false)
            XCTAssertTrue(close.exists)
            agent.tap()
            XCTAssertEqual(composer.value as? String, editedDraft)
            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: Self.timeout))
            XCTAssertTrue(composer.waitForExistence(timeout: Self.timeout))
            XCTAssertGreaterThan(composer.frame.minX, app.frame.width / 3)
            XCTAssertEqual(composer.value as? String, editedDraft)
            capture(app, "ipad-tool-restored-\(appearance)")
            verifyWorkspaceSwitch(afterDragging: browser, in: app)
            app.terminate()
        }
    }

    @MainActor
    func testTerminalDragAllowsAgentSelectionAndLeavesShellRunning() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad tool placement")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            app.buttons["Workspace actions"].firstMatch.tap()
            app.buttons["New terminal"].tap()
            let title = app.staticTexts["mobile-terminal-title"]
            XCTAssertTrue(title.waitForExistence(timeout: Self.timeout))
            app.buttons["Back to workspace"].tap()
            let agent = app.buttons["workspace.agent.demo-agent-implementor"]
            XCTAssertTrue(agent.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
            agent.tap()
            let terminal = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'terminal.row.'")).firstMatch
            reveal(terminal, in: app)
            drag(terminal, into: app)
            XCTAssertTrue(title.waitForExistence(timeout: Self.timeout))
            let composer = app.textViews["composer.textView"]
            XCTAssertTrue(composer.waitForExistence(timeout: Self.timeout))
            XCTAssertLessThan(composer.frame.maxX, title.frame.minX)
            let keyboardToggle = app.buttons["terminal.keyboard.toggle"]
            XCTAssertTrue(keyboardToggle.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
            if keyboardToggle.label == "Hide keyboard" { keyboardToggle.tap() }
            capture(app, "ipad-tool-terminal-chat-\(appearance)")
            composer.tap()
            composer.typeText("Explain this output")
            XCTAssertFalse(app.buttons["ipad.focus.close"].exists)
            XCTAssertLessThan(composer.frame.maxX, title.frame.minX)
            app.buttons["conversation.back"].tap()
            reveal(agent, in: app, scrollingUp: false)
            agent.tap()
            XCTAssertTrue(title.exists)
            XCTAssertEqual(composer.value as? String, "Explain this output")
            app.buttons["Back to workspace"].tap()
            XCTAssertTrue(title.waitForNonExistence(timeout: Self.timeout))
            reveal(terminal, in: app)
            terminal.tap()
            XCTAssertTrue(title.waitForExistence(timeout: Self.timeout), "Closing the pane leaves the terminal session running")
            app.terminate()
        }
    }

    @MainActor
    private func verifyWorkspaceSwitch(afterDragging browser: XCUIElement, in app: XCUIApplication) {
        reveal(browser, in: app)
        drag(browser, into: app)
        let close = app.buttons["Close main browser"]
        XCTAssertTrue(close.waitForExistence(timeout: Self.timeout))
        app.buttons["conversation.back"].tap()
        app.buttons["ipad.rail.workspaces"].tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: Self.timeout))
        let workspace = app.buttons["workspace.row.demo-ws-reconnect"]
        XCTAssertTrue(workspace.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        workspace.tap()
        XCTAssertTrue(app.staticTexts["workspace.title.heading"].wait(for: \.label, toEqual: "Fix websocket reconnect storm", timeout: Self.timeout))
    }

    @MainActor
    private func launch(_ appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "--demo-browsers", "-appThemePreference", appearance]
        app.launch()
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
        workspace.tap()
        return app
    }

    @MainActor
    private func reveal(_ row: XCUIElement, in app: XCUIApplication, scrollingUp: Bool = true) {
        let sidebar = app.scrollViews["workspace.detail.scroll"].firstMatch
        for _ in 0..<6 where !row.isHittable {
            if scrollingUp { sidebar.swipeUp() } else { sidebar.swipeDown() }
        }
        XCTAssertTrue(row.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
    }

    @MainActor
    private func drag(_ row: XCUIElement, into app: XCUIApplication) {
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.6, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.45)))
    }

    @MainActor
    private func capture(_: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
