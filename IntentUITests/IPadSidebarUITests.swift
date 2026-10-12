import XCTest

nonisolated final class IPadSidebarUITests: XCTestCase {
    private static let timeout: TimeInterval = 30
    private static let draft = "Keep this workspace draft"

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        continueAfterFailure = true
        try super.tearDownWithError()
    }

    @MainActor
    func testSectionsAndPairingRestoreConversationInBothThemes() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad sidebar navigation")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            captureFirstWorkspaceSelection(in: app, appearance: appearance)
            openConversation(in: app)
            captureMainScreens(in: app, appearance: appearance)
            let composer = try app.textViews.matching(identifier: "composer.textView").singleHittableElement()
            composer.tap()
            composer.typeText(Self.draft)
            try verifySections(in: app)
            try verifyPairingCancellation(in: app, appearance: appearance)
            XCTAssertEqual(composer.value as? String, Self.draft)
            app.terminate()
        }
    }

    @MainActor
    func testRailRemainsReachableWithAccessibilityText() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad sidebar navigation")
        XCUIDevice.shared.orientation = .portrait
        let app = launch(appearance: "dark", accessibility: true)
        for destination in ["assistant", "workspaces", "connections", "settings"] {
            let button = app.buttons["ipad.rail.\(destination)"]
            XCTAssertTrue(button.isHittable)
            button.tap()
            XCTAssertTrue(button.wait(for: \.isSelected, toEqual: true, timeout: Self.timeout))
            XCTAssertTrue(app.buttons["ipad.rail.appearance"].isHittable)
        }
        let manual = app.buttons["settings.pairing.manual"]
        XCTAssertTrue(manual.waitForExistence(timeout: Self.timeout))
        let settings = app.scrollViews["settings.scroll"]
        for _ in 0..<3 where !manual.isHittable { settings.swipeUp() }
        capture(app, name: "iPad accessibility Settings")
        XCTAssertTrue(manual.isHittable, app.debugDescription)
        manual.tap()
        XCTAssertTrue(app.textFields["manual.host"].waitForExistence(timeout: Self.timeout))
        capture(app, name: "iPad accessibility manual pairing")
        XCTAssertTrue(app.buttons["ipad.pairing.cancel"].isHittable, app.debugDescription)
        app.buttons["ipad.pairing.cancel"].tap()
        XCTAssertTrue(app.buttons["ipad.rail.workspaces"].isHittable)
    }

    @MainActor
    func testRepeatedAgentSelectionReturnsFromChildAndPreservesDraft() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad retained conversation navigation")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let trigger = FileManager.default.temporaryDirectory.appendingPathComponent("ipad-reselect-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: trigger) }
        let app = launch(appearance: "light", extraArguments: ["--demo-conversation-reselection-trigger-file=\(trigger.path)"])
        defer { app.terminate() }
        let workspace = app.buttons["workspace.row.demo-ws-flaky-tests"]
        XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
        workspace.tap()
        let agent = app.buttons["workspace.agent.demo-agent-deflake"]
        XCTAssertTrue(agent.waitForExistence(timeout: Self.timeout))
        agent.tap()
        let composer = app.textViews["composer.textView"]
        XCTAssertTrue(composer.waitForExistence(timeout: Self.timeout))
        composer.tap()
        composer.typeText(Self.draft)
        let child = app.buttons["watched-agent-demo-agent-deflake-capture"]
        app.buttons["Hide keyboard"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(child.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        child.tap()
        let childTitle = app.staticTexts["Capture Race Fixer, Agent"]
        XCTAssertTrue(childTitle.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        app.buttons["ipad.rail.settings"].tap()
        app.buttons["ipad.rail.workspaces"].tap()
        XCTAssertTrue(childTitle.isHittable, "Section changes must retain the pushed conversation")
        try Data().write(to: trigger)
        let parentTitle = app.staticTexts["Test Stabilizer, Agent"]
        XCTAssertTrue(parentTitle.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        XCTAssertTrue(childTitle.waitForNonExistence(timeout: Self.timeout))
        XCTAssertEqual(try app.textViews.matching(identifier: "composer.textView").singleHittableElement().value as? String, Self.draft)
        XCTAssertTrue(app.buttons["ipad.rail.workspaces"].isSelected)
    }

    @MainActor
    func testRepeatedSidebarTogglesWithAgentHistoryPreserveDraft() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad sidebar toggling")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(appearance: "dark", extraArguments: ["--demo-settings"])
        defer { app.terminate() }
        openConversation(in: app)
        let composer = try app.textViews.matching(identifier: "composer.textView").singleHittableElement()
        composer.tap()
        composer.typeText(Self.draft)
        verifyPopulatedHistory(in: app)
        let collapse = app.buttons["ipad.sidebar.collapse"]
        let expand = app.buttons["ipad.sidebar.expand"]
        for _ in 0..<12 {
            XCTAssertTrue(collapse.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
            collapse.tap()
            XCTAssertTrue(expand.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
            expand.tap()
        }
        XCTAssertTrue(collapse.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        XCTAssertEqual(composer.value as? String, Self.draft)
        verifyPopulatedHistory(in: app)
    }

    @MainActor
    private func verifyPopulatedHistory(in app: XCUIApplication) {
        app.buttons["workspaces.menu"].tap()
        app.buttons["workspaces.menu.recentAgents"].tap()
        let entry = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
            "agent-history.entry.",
            "/demo-agent-implementor"
        )).firstMatch
        XCTAssertTrue(entry.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        let close = app.buttons["agent-history.close"]
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: Self.timeout))
    }

    @MainActor
    private func captureFirstWorkspaceSelection(in app: XCUIApplication, appearance: String) {
        let recent = app.buttons["workspaces.viewMode.Recent"]
        recent.tap()
        XCTAssertTrue(recent.wait(for: \.isSelected, toEqual: true, timeout: Self.timeout))
        let workspace = app.buttons["workspace.row.demo-ws-reconnect"]
        XCTAssertTrue(workspace.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        workspace.tap()
        XCTAssertTrue(app.buttons["workspace.agent.demo-agent-backoff"].waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Self.timeout))
        capture(app, name: "iPad first workspace selected \(appearance)")
    }

    @MainActor
    private func captureMainScreens(in app: XCUIApplication, appearance: String) {
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Self.timeout))
        for mode in ["Repo", "Status", "Recent"] {
            let control = app.buttons["workspaces.viewMode.\(mode)"]
            control.tap()
            XCTAssertTrue(control.wait(for: \.isSelected, toEqual: true, timeout: Self.timeout))
            capture(app, name: "iPad \(mode) sidebar \(appearance)")
        }
        capture(app, name: "iPad workspace \(appearance)")
        app.buttons["ipad.sidebar.collapse"].tap()
        XCTAssertTrue(app.buttons["ipad.sidebar.expand"].waitForExistence(timeout: Self.timeout))
        capture(app, name: "iPad collapsed \(appearance)")
        app.buttons["ipad.sidebar.expand"].tap()
        let sections = [
            ("assistant", "Assistant", "assistant.sidebar.newConversation"),
            ("connections", "connections", "saved-connections.scan"),
            ("settings", "settings", "settings.pairing.scan")
        ]
        for (section, label, control) in sections {
            app.buttons["ipad.rail.\(section)"].tap()
            XCTAssertTrue(app.buttons["ipad.rail.\(section)"].wait(for: \.isSelected, toEqual: true, timeout: Self.timeout))
            XCTAssertTrue(app.buttons[control].wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Self.timeout))
            capture(app, name: "iPad \(label) \(appearance)")
            app.buttons["ipad.rail.workspaces"].tap()
        }
    }

    @MainActor
    private func verifySections(in app: XCUIApplication) throws {
        app.buttons["ipad.rail.assistant"].tap()
        XCTAssertTrue(app.buttons["assistant.sidebar.newConversation"].waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(try app.textViews.matching(identifier: "composer.textView").singleHittableElement().value as? String, "")
        app.buttons["ipad.rail.workspaces"].tap()
        let composer = try app.textViews.matching(identifier: "composer.textView").singleHittableElement()
        XCTAssertEqual(composer.value as? String, Self.draft)
        for section in ["connections", "settings"] {
            app.buttons["ipad.rail.\(section)"].tap()
            XCTAssertTrue(app.buttons["ipad.rail.\(section)"].isSelected)
            XCTAssertEqual(composer.value as? String, Self.draft)
        }
    }

    @MainActor
    private func verifyPairingCancellation(in app: XCUIApplication, appearance: String) throws {
        app.buttons["settings.pairing.scan"].tap()
        let cancel = app.buttons["ipad.pairing.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: Self.timeout))
        XCTAssertFalse(app.textViews.matching(identifier: "composer.textView").allElementsBoundByIndex.contains { $0.isHittable })
        XCTAssertTrue(app.buttons["ipad.rail.connections"].isHittable)
        capture(app, name: "iPad QR \(appearance)")
        cancel.tap()
        XCTAssertEqual(try app.textViews.matching(identifier: "composer.textView").singleHittableElement().value as? String, Self.draft)
        app.buttons["settings.pairing.manual"].tap()
        let host = app.textFields["manual.host"]
        XCTAssertTrue(host.waitForExistence(timeout: Self.timeout))
        host.tap()
        host.typeText("example.local")
        XCTAssertTrue(cancel.isHittable)
        capture(app, name: "iPad manual \(appearance)")
        cancel.tap()
        XCTAssertEqual(try app.textViews.matching(identifier: "composer.textView").singleHittableElement().value as? String, Self.draft)
        XCTAssertFalse(host.exists)
        app.buttons["ipad.rail.workspaces"].tap()
    }

    @MainActor
    private func launch(appearance: String, accessibility: Bool = false, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "-appThemePreference", appearance] + extraArguments
        if accessibility {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.buttons["ipad.rail.workspaces"].waitForExistence(timeout: Self.timeout))
        return app
    }

    @MainActor
    private func openConversation(in app: XCUIApplication) {
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Self.timeout))
        workspace.tap()
        let agent = app.buttons["workspace.agent.demo-agent-implementor"]
        XCTAssertTrue(agent.waitForExistence(timeout: Self.timeout))
        agent.tap()
        XCTAssertTrue(app.textViews["composer.textView"].waitForExistence(timeout: Self.timeout))
    }

    @MainActor
    private func capture(_: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
