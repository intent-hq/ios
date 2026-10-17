import XCTest

nonisolated final class IPadAssistantSwipeUITests: XCTestCase {
    private static let timeout: TimeInterval = 30
    private static let currentID = "demo-agent-assistant"
    private static let otherID = "demo-assistant-history-0"
    private static let swipeStart = CGVector(dx: 0.8, dy: 0.5)
    private static let swipeDistance: CGFloat = -100
    private static let pressDuration: TimeInterval = 0.05

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        continueAfterFailure = true
        try super.tearDownWithError()
    }

    @MainActor
    func testSwipeDeletionPreservesSelectionAndSupportsCancellationInBothThemes() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad assistant swipe deletion")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance, history: true)
            defer { app.terminate() }
            let current = app.buttons["assistant.thread.\(Self.currentID)"]
            let other = app.buttons["assistant.thread.\(Self.otherID)"]
            XCTAssertTrue(current.isSelected)
            revealDelete(in: app, id: Self.otherID)
            capture(app, name: "iPad Assistant swipe delete \(appearance)")
            app.buttons["assistant.thread.delete.\(Self.otherID)"].tap()
            let alert = app.alerts["Delete Conversation?"]
            XCTAssertTrue(alert.waitForExistence(timeout: Self.timeout))
            alert.buttons["Cancel"].tap()
            XCTAssertTrue(other.exists)
            XCTAssertTrue(current.isSelected)

            delete(in: app, id: Self.otherID)
            XCTAssertTrue(other.waitForNonExistence(timeout: Self.timeout))
            XCTAssertTrue(current.isSelected)
            delete(in: app, id: Self.currentID)
            XCTAssertTrue(current.waitForNonExistence(timeout: Self.timeout))
            let selected = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND selected == true", "assistant.thread."
            )).firstMatch
            XCTAssertTrue(selected.waitForExistence(timeout: Self.timeout))
            XCTAssertTrue(app.textViews["composer.textView"].firstMatch.waitForExistence(timeout: Self.timeout))
        }
    }

    @MainActor
    func testDeletingLastConversationShowsEmptyState() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad assistant swipe deletion")
        let app = launch(appearance: "light", history: false)
        defer { app.terminate() }
        delete(in: app, id: Self.currentID)
        XCTAssertTrue(app.buttons["assistant.thread.\(Self.currentID)"].waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["assistant.sidebar.newConversation"].isEnabled)
        app.buttons["ipad.sidebar.collapse"].tap()
        let start = app.buttons["assistant.startConversation"].firstMatch
        XCTAssertTrue(start.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        XCTAssertFalse(app.textViews["composer.textView"].firstMatch.exists)
        start.tap()
        XCTAssertTrue(app.textViews["composer.textView"].firstMatch.waitForExistence(timeout: Self.timeout))
    }

    @MainActor
    private func launch(appearance: String, history: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "-appThemePreference", appearance]
        if history { app.launchArguments.append("--demo-assistant-history") }
        app.launch()
        let workspaces = app.buttons["ipad.rail.workspaces"]
        XCTAssertTrue(workspaces.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        workspaces.tap()
        let assistant = app.buttons["ipad.rail.assistant"]
        XCTAssertTrue(assistant.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        assistant.tap()
        XCTAssertTrue(assistant.wait(for: \.isSelected, toEqual: true, timeout: Self.timeout))
        XCTAssertTrue(app.buttons["assistant.thread.\(Self.currentID)"].waitForExistence(timeout: Self.timeout))
        return app
    }

    @MainActor
    private func revealDelete(in app: XCUIApplication, id: String) {
        let row = app.buttons["assistant.thread.\(id)"]
        XCTAssertTrue(row.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        let start = row.coordinate(withNormalizedOffset: Self.swipeStart)
        start.press(forDuration: Self.pressDuration, thenDragTo: start.withOffset(CGVector(dx: Self.swipeDistance, dy: 0)))
        XCTAssertTrue(app.buttons["assistant.thread.delete.\(id)"].wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
    }

    @MainActor
    private func delete(in app: XCUIApplication, id: String) {
        revealDelete(in: app, id: id)
        app.buttons["assistant.thread.delete.\(id)"].tap()
        let alert = app.alerts["Delete Conversation?"]
        XCTAssertTrue(alert.waitForExistence(timeout: Self.timeout))
        alert.buttons["Delete"].tap()
    }

    @MainActor
    private func capture(_: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
