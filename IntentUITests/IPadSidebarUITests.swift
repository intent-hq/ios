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
            capture(app, name: "iPad workspace \(appearance)")
            app.buttons["ipad.sidebar.collapse"].tap()
            XCTAssertTrue(app.buttons["ipad.sidebar.expand"].waitForExistence(timeout: Self.timeout))
            capture(app, name: "iPad collapsed \(appearance)")
            app.buttons["ipad.sidebar.expand"].tap()
            let composer = app.textViews["composer.textView"]
            composer.tap()
            composer.typeText(Self.draft)
            verifySections(in: app, appearance: appearance)
            verifyPairingCancellation(in: app, appearance: appearance)
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
        if !manual.isHittable { app.swipeUp() }
        XCTAssertTrue(manual.isHittable)
        manual.tap()
        XCTAssertTrue(app.textFields["manual.host"].waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["ipad.pairing.cancel"].isHittable)
        capture(app, name: "iPad accessibility manual pairing")
        app.buttons["ipad.pairing.cancel"].tap()
        XCTAssertTrue(app.buttons["ipad.rail.workspaces"].isHittable)
    }

    @MainActor
    private func verifySections(in app: XCUIApplication, appearance: String) {
        app.buttons["ipad.rail.assistant"].tap()
        XCTAssertTrue(app.buttons["assistant.sidebar.newConversation"].waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.textViews["composer.textView"].waitForExistence(timeout: Self.timeout))
        capture(app, name: "iPad Assistant \(appearance)")
        app.buttons["ipad.rail.workspaces"].tap()
        let composer = app.textViews["composer.textView"]
        XCTAssertTrue(composer.waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(composer.value as? String, Self.draft)
        for section in ["connections", "settings"] {
            app.buttons["ipad.rail.\(section)"].tap()
            XCTAssertTrue(app.buttons["ipad.rail.\(section)"].isSelected)
            XCTAssertEqual(composer.value as? String, Self.draft)
            capture(app, name: "iPad \(section) \(appearance)")
        }
    }

    @MainActor
    private func verifyPairingCancellation(in app: XCUIApplication, appearance: String) {
        app.buttons["settings.pairing.scan"].tap()
        let cancel = app.buttons["ipad.pairing.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: Self.timeout))
        XCTAssertFalse(app.textViews["composer.textView"].exists)
        XCTAssertTrue(app.buttons["ipad.rail.connections"].isHittable)
        capture(app, name: "iPad QR \(appearance)")
        cancel.tap()
        XCTAssertTrue(app.textViews["composer.textView"].waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(app.textViews["composer.textView"].value as? String, Self.draft)
        app.buttons["settings.pairing.manual"].tap()
        let host = app.textFields["manual.host"]
        XCTAssertTrue(host.waitForExistence(timeout: Self.timeout))
        host.tap()
        host.typeText("example.local")
        XCTAssertTrue(cancel.isHittable)
        capture(app, name: "iPad manual \(appearance)")
        cancel.tap()
        XCTAssertTrue(app.textViews["composer.textView"].waitForExistence(timeout: Self.timeout))
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
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
