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
    private func captureMainScreens(in app: XCUIApplication, appearance: String) {
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Self.timeout))
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
    private func launch(appearance: String, accessibility: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "-appThemePreference", appearance]
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
