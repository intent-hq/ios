import XCTest

/// Exercises the real Settings routes with ephemeral saved machines and no daemon.
nonisolated final class SettingsUITests: XCTestCase {
    private static let timeout: TimeInterval = 15
    private static let maximumSwipes = 12

    @MainActor
    func testAppearancePersistsAcrossCloseAndLaunchWithLightDarkScreenshots() {
        let app = launch()
        openSettings(app)
        let light = app.buttons["settings.appearance.light"]
        light.tap()
        XCTAssertTrue(light.isSelected)
        capture(app, named: "Settings-Light")
        assertPinnedLogOffAndRevealActions(app)
        capture(app, named: "Settings-Light-Actions")
        scrollToTop(app)
        let dark = app.buttons["settings.appearance.dark"]
        dark.tap()
        XCTAssertTrue(dark.isSelected)
        capture(app, named: "Settings-Dark")
        app.buttons["settings.close"].tap()
        openSettings(app)
        XCTAssertTrue(dark.isSelected)
        app.terminate()
        app.launch()
        openSettings(app)
        XCTAssertTrue(dark.isSelected, "Theme selection must survive a fresh process")
        let system = app.buttons["settings.appearance.system"]
        system.tap()
        XCTAssertTrue(system.isSelected)
        app.buttons["settings.close"].tap()
        openSettings(app)
        XCTAssertTrue(system.isSelected)
    }

    @MainActor
    func testSavedConnectionSelectionUsesWindowRouting() {
        let app = launch()
        openSettings(app)
        assertConnections(app, current: "Studio Mac", other: "Travel Mac")
        card(app, named: "Studio Mac").tap()
        XCTAssertTrue(app.buttons["Workspace options"].waitForExistence(timeout: Self.timeout))
        openSettings(app)
        card(app, named: "Travel Mac").tap()
        XCTAssertTrue(app.buttons["Workspace options"].waitForExistence(timeout: Self.timeout))
        openSettings(app)
        assertConnections(app, current: "Travel Mac", other: "Studio Mac")
    }

    @MainActor
    func testPairingCancellationAndAcknowledgementsReturnToSettings() {
        let app = launch()
        openSettings(app)
        reveal(app.buttons["Manual Connection"], in: app)
        app.buttons["Manual Connection"].tap()
        let manual = app.navigationBars["Manual Connection"]
        XCTAssertTrue(manual.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["Connect"].exists)
        manual.buttons["Cancel"].tap()
        XCTAssertTrue(manual.waitForNonExistence(timeout: Self.timeout))
        reveal(app.buttons["QR Code"], in: app)
        app.buttons["QR Code"].tap()
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: Self.timeout))
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: Self.timeout))
        reveal(app.buttons["Acknowledgements"], in: app)
        app.buttons["Acknowledgements"].tap()
        let acknowledgements = app.navigationBars["Acknowledgements"]
        XCTAssertTrue(acknowledgements.waitForExistence(timeout: Self.timeout))
        acknowledgements.buttons.firstMatch.tap()
        XCTAssertTrue(acknowledgements.waitForNonExistence(timeout: Self.timeout))
        scrollToTop(app)
        assertConnections(app, current: "Studio Mac", other: "Travel Mac")
        XCTAssertTrue(app.buttons["settings.close"].isHittable)
    }

    @MainActor
    func testLargeTextKeepsPairingSupportAndLogOffCancellationReachable() {
        let app = launch(largeText: true)
        openSettings(app)
        app.buttons["settings.appearance.light"].tap()
        capture(app, named: "Settings-LargeText-Top")
        assertPinnedLogOffAndRevealActions(app)
        capture(app, named: "Settings-LargeText-Actions")
        app.buttons["Log Off"].tap()
        let confirmation = app.alerts["Log Off?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: Self.timeout))
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: Self.timeout))
        scrollToTop(app)
        assertConnections(app, current: "Studio Mac", other: "Travel Mac")
    }

    @MainActor
    private func assertPinnedLogOffAndRevealActions(_ app: XCUIApplication) {
        let logOff = app.buttons["Log Off"]
        XCTAssertTrue(logOff.isHittable, "Log Off must be available before scrolling")
        let initialFrame = logOff.frame
        XCTAssertTrue(app.frame.contains(initialFrame), "The full Log Off button must remain on screen")
        XCTAssertGreaterThanOrEqual(initialFrame.height, 44)
        for title in ["Manual Connection", "Acknowledgements", "Export logs"] {
            let button = app.buttons[title]
            reveal(button, in: app)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertLessThanOrEqual(button.frame.maxY, logOff.frame.minY, "The footer must not obscure \(title)")
            XCTAssertTrue(logOff.isHittable)
            XCTAssertEqual(logOff.frame.minY, initialFrame.minY, accuracy: 1, "Log Off must stay anchored while scrolling")
        }
    }

    @MainActor
    private func launch(largeText: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-settings", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]
        }
        app.launch()
        return app
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        let options = app.buttons["Workspace options"]
        XCTAssertTrue(options.waitForExistence(timeout: Self.timeout))
        options.tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["settings.close"].waitForExistence(timeout: Self.timeout))
    }

    @MainActor
    private func card(_ app: XCUIApplication, named name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "settings.connection.", name)).firstMatch
    }

    @MainActor
    private func assertConnections(_ app: XCUIApplication, current: String, other: String) {
        let selected = card(app, named: current)
        XCTAssertTrue(selected.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(selected.isSelected)
        XCTAssertTrue(selected.label.contains("Connected"))
        let saved = card(app, named: other)
        XCTAssertTrue(saved.exists)
        XCTAssertFalse(saved.isSelected)
        XCTAssertFalse(saved.label.contains("Connected"))
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let logOff = app.buttons["Log Off"]
        for _ in 0..<Self.maximumSwipes where !element.isHittable || element.frame.maxY > logOff.frame.minY {
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func scrollToTop(_ app: XCUIApplication) {
        for _ in 0..<Self.maximumSwipes where !app.buttons["settings.close"].isHittable { app.swipeDown() }
    }

    @MainActor
    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
