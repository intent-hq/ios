import XCTest

nonisolated final class IPhoneAssistantHistoryUITests: XCTestCase {
    private static let timeout: TimeInterval = 30
    private static let notificationTimeout: TimeInterval = 2
    private static let currentID = "demo-agent-assistant"
    private static let otherID = "demo-assistant-history-0"
    private static let draft = "Keep this Assistant draft"

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        continueAfterFailure = true
        try super.tearDownWithError()
    }

    @MainActor
    func testSwipeDeletionPreservesDraftAndSelectionInBothThemes() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone Assistant history")
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance, history: true)
            defer { app.terminate() }
            let composer = app.textViews["composer.textView"].firstMatch
            XCTAssertTrue(composer.appears(timeout: Self.timeout))
            composer.tap()
            composer.typeText(Self.draft)
            openHistory(in: app)
            let current = row(in: app, id: Self.currentID)
            let other = row(in: app, id: Self.otherID)
            XCTAssertTrue(current.isSelected)
            revealDelete(in: app, id: Self.otherID)
            capture(name: "iPhone Assistant history swipe delete \(appearance)")
            app.buttons["assistant.history.delete.\(Self.otherID)"].tap()
            let alert = app.alerts["Delete Conversation?"]
            XCTAssertTrue(alert.appears(timeout: Self.timeout))
            alert.buttons["Cancel"].tap()
            XCTAssertTrue(other.exists)
            XCTAssertTrue(current.isSelected)
            delete(in: app, id: Self.otherID)
            XCTAssertTrue(other.disappears(timeout: Self.timeout))
            XCTAssertTrue(current.isSelected)
            app.buttons["assistant.history.close"].tap()
            XCTAssertTrue(composer.appears(timeout: Self.timeout))
            XCTAssertEqual(composer.value as? String, Self.draft)
            openHistory(in: app)
            delete(in: app, id: Self.currentID)
            XCTAssertTrue(current.disappears(timeout: Self.timeout))
            let selected = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND selected == true", "assistant.history.thread."
            )).firstMatch
            XCTAssertTrue(selected.appears(timeout: Self.timeout))
            selected.tap()
            XCTAssertTrue(app.buttons["assistant.history.close"].disappears(timeout: Self.timeout))
            XCTAssertTrue(composer.appears(timeout: Self.timeout))
            XCTAssertEqual(composer.value as? String, "")
        }
    }

    @MainActor
    func testDeletingLastChatKeepsHistoryOpenAndCanCreateConversation() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone Assistant history")
        let app = launch(appearance: "light", history: false)
        defer { app.terminate() }
        openHistory(in: app)
        delete(in: app, id: Self.currentID)
        XCTAssertTrue(row(in: app, id: Self.currentID).disappears(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["assistant.history.close"].exists)
        XCTAssertTrue(app.buttons["assistant.startConversation"].appears(timeout: Self.timeout))
        let newConversation = app.buttons["assistant.history.newConversation"]
        XCTAssertTrue(newConversation.isEnabled)
        newConversation.tap()
        XCTAssertTrue(app.buttons["assistant.history.close"].disappears(timeout: Self.timeout))
        XCTAssertTrue(app.textViews["composer.textView"].firstMatch.appears(timeout: Self.timeout))
        openHistory(in: app)
        XCTAssertFalse(row(in: app, id: Self.currentID).exists)
        let created = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "assistant.history.thread.demo-assistant-created-"
        )).firstMatch
        XCTAssertTrue(created.appears(timeout: Self.timeout))
    }

    @MainActor
    private func launch(appearance: String, history: Bool) -> XCUIApplication {
        let app = XCUIApplication.intent()
        app.launchArguments = ["--demo-data", "-appThemePreference", appearance]
        if history { app.launchArguments.append("--demo-assistant-history") }
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.appears(timeout: Self.notificationTimeout) { allow.tap() }
        let launcher = app.buttons["intent.menu.open"]
        XCTAssertTrue(launcher.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        launcher.tap()
        let assistant = app.buttons["intent.menu.assistant"]
        XCTAssertTrue(assistant.appears(timeout: Self.timeout))
        assistant.tap()
        XCTAssertTrue(app.buttons["assistant.actions"].appears(timeout: Self.timeout))
        return app
    }

    @MainActor
    private func openHistory(in app: XCUIApplication) {
        app.buttons["assistant.actions"].tap()
        let history = app.buttons["assistant.conversations"]
        XCTAssertTrue(history.appears(timeout: Self.timeout))
        history.tap()
        XCTAssertTrue(app.buttons["assistant.history.close"].appears(timeout: Self.timeout))
    }

    @MainActor
    private func row(in app: XCUIApplication, id: String) -> XCUIElement {
        app.buttons["assistant.history.thread.\(id)"]
    }

    @MainActor
    private func revealDelete(in app: XCUIApplication, id: String) {
        let chat = row(in: app, id: id)
        XCTAssertTrue(chat.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        chat.swipeLeft()
        XCTAssertTrue(app.buttons["assistant.history.delete.\(id)"].wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
    }

    @MainActor
    private func delete(in app: XCUIApplication, id: String) {
        revealDelete(in: app, id: id)
        app.buttons["assistant.history.delete.\(id)"].tap()
        let alert = app.alerts["Delete Conversation?"]
        XCTAssertTrue(alert.appears(timeout: Self.timeout))
        alert.buttons["Delete"].tap()
    }

    @MainActor
    private func capture(name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
