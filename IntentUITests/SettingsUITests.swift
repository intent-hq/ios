import XCTest

nonisolated final class SettingsUITests: XCTestCase {
    private static let timeout: TimeInterval = 15
    private static let maximumSwipes = 12

    private static func header(_ title: String, in root: XCUIElement) -> XCUIElement {
        root.staticTexts.matching(NSPredicate(format: "label ==[c] %@", title)).firstMatch
    }

    @MainActor
    func testSavedConnectionSelectionUsesWindowRouting() {
        let app = launch()
        openConnections(app)
        assertConnections(app, current: "Studio Mac", other: "Travel Mac")
        card(app, named: "Studio Mac").tap()
        XCTAssertTrue(app.buttons["intent.menu.open"].appears(timeout: Self.timeout))
        openConnections(app)
        card(app, named: "Travel Mac").tap()
        XCTAssertTrue(app.buttons["intent.menu.open"].appears(timeout: Self.timeout))
        openConnections(app)
        assertConnections(app, current: "Travel Mac", other: "Studio Mac")

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: Self.timeout))
        app.activate()
        assertConnections(app, current: "Travel Mac", other: "Studio Mac")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: Self.timeout))
        app.terminate()
        app.launch()
        openConnections(app)
        assertConnections(app, current: "Studio Mac", other: "Travel Mac")
        card(app, named: "Travel Mac").tap()
        XCTAssertTrue(app.buttons["intent.menu.open"].appears(timeout: Self.timeout))
        openConnections(app)
        assertConnections(app, current: "Travel Mac", other: "Studio Mac")
    }

    @MainActor
    func testLiveActivitiesToggleSwitchesOffAndOn() {
        let app = launch()
        openSettings(app)
        let toggle = app.scrollViews["settings.scroll"].switches["settings.liveActivities"]
        XCTAssertTrue(toggle.appears(timeout: Self.timeout))
        XCTAssertEqual(toggle.value as? String, "1")
        let control = toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
        control.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        capture(app, named: "Settings-LiveActivities-Off")
        control.tap()
        XCTAssertEqual(toggle.value as? String, "1")
    }

    @MainActor
    func testPairingCancellationAndAcknowledgementsReturnToSettings() {
        let app = launch()
        openSettings(app)
        reveal(app.buttons["Manual Connection"], in: app)
        app.buttons["Manual Connection"].tap()
        let manual = app.staticTexts["manual.title"]
        XCTAssertTrue(manual.appears(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["manual.connect"].exists)
        app.buttons["connection-sheet.close"].tap()
        XCTAssertTrue(manual.disappears(timeout: Self.timeout))
        reveal(app.buttons["QR Code"], in: app)
        app.buttons["QR Code"].tap()
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.appears(timeout: Self.timeout))
        cancel.tap()
        XCTAssertTrue(cancel.disappears(timeout: Self.timeout))
        reveal(app.buttons["Acknowledgements"], in: app)
        app.buttons["Acknowledgements"].tap()
        let acknowledgements = app.navigationBars["Acknowledgements"]
        XCTAssertTrue(acknowledgements.appears(timeout: Self.timeout))
        capture(app, named: "Settings-Acknowledgements")
        acknowledgements.buttons.firstMatch.tap()
        XCTAssertTrue(acknowledgements.disappears(timeout: Self.timeout))
        scrollToTop(app)
        XCTAssertTrue(Self.header("New Connection", in: app).exists)
        XCTAssertTrue(app.buttons["settings.close"].isHittable)
    }

    @MainActor
    func testLogOffRequiresConfirmationAndCanBeCancelled() {
        let app = launch()
        openSettings(app)
        let logOff = app.buttons["Disconnect"]
        reveal(logOff, in: app)
        logOff.tap()
        let confirmation = app.staticTexts["log-off.title"]
        XCTAssertTrue(confirmation.appears(timeout: Self.timeout))
        XCTAssertEqual(confirmation.label, "Disconnect from Studio Mac?")
        app.buttons["log-off.cancel"].tap()
        XCTAssertTrue(confirmation.disappears(timeout: Self.timeout))
        reveal(logOff, in: app)
        logOff.tap()
        XCTAssertTrue(confirmation.appears(timeout: Self.timeout))
        app.buttons["connection-sheet.close"].tap()
        XCTAssertTrue(confirmation.disappears(timeout: Self.timeout))
        scrollToTop(app)
        XCTAssertTrue(Self.header("New Connection", in: app).exists)
    }

    @MainActor
    func testConfirmedLogOffForgetsOnlyTheCurrentConnection() {
        let app = launch(themePreference: "dark")
        openSettings(app)
        let logOff = app.buttons["Disconnect"]
        reveal(logOff, in: app)
        logOff.tap()
        let confirmation = app.staticTexts["log-off.title"]
        XCTAssertTrue(confirmation.appears(timeout: Self.timeout))
        capture(app, named: "Log-Off-Dark")
        app.buttons["log-off.confirm"].tap()
        XCTAssertTrue(confirmation.disappears(timeout: Self.timeout))
        app.openHomeAction("connections")
        XCTAssertTrue(app.staticTexts["saved-connections.title"].appears(timeout: Self.timeout))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Travel Mac")).firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Studio Mac")).firstMatch.exists)
    }

    @MainActor
    private func launch(largeText: Bool = false, themePreference: String = "system") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication.intent()
        app.launchArguments += ["--demo-data", "--demo-settings", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-appThemePreference", themePreference]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]
        }
        app.launch()
        return app
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        app.openHomeAction("settings")
        XCTAssertTrue(app.buttons["settings.close"].appears(timeout: Self.timeout))
    }

    @MainActor
    private func openConnections(_ app: XCUIApplication) {
        app.openHomeAction("connections")
        XCTAssertTrue(app.staticTexts["saved-connections.title"].appears(timeout: Self.timeout))
    }

    @MainActor
    private func card(_ app: XCUIApplication, named name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "saved-connection.", name)).firstMatch
    }

    @MainActor
    private func assertConnections(_ app: XCUIApplication, current: String, other: String) {
        let selected = card(app, named: current)
        XCTAssertTrue(selected.appears(timeout: Self.timeout))
        XCTAssertTrue(selected.label.contains("Connected"))
        let saved = card(app, named: other)
        XCTAssertTrue(saved.exists)
        XCTAssertFalse(saved.label.contains("Connected"))
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let scrollView = app.scrollViews["settings.scroll"]
        let viewport = scrollView.frame.intersection(app.frame)
        for _ in 0..<Self.maximumSwipes {
            if element.isHittable, viewport.contains(element.frame) { break }
            scrollView.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
        XCTAssertTrue(viewport.contains(element.frame), "The full action must be reachable inside the Settings viewport")
    }

    @MainActor
    private func scrollToTop(_ app: XCUIApplication) {
        for _ in 0..<Self.maximumSwipes {
            if app.buttons["settings.close"].isHittable { break }
            app.scrollViews["settings.scroll"].swipeDown()
        }
    }

    @MainActor
    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
