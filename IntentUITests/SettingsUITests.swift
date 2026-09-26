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
        assertScrollingLogOffAndRevealActions(app)
        capture(app, named: "Settings-Light-Actions")
        scrollToTop(app)
        let dark = app.buttons["settings.appearance.dark"]
        dark.tap()
        XCTAssertTrue(dark.isSelected)
        capture(app, named: "Settings-Dark")
        assertScrollingLogOffAndRevealActions(app)
        capture(app, named: "Settings-Dark-Actions")
        scrollToTop(app)
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

        // Resuming this process must keep the user's selection. Backgrounding
        // also gives the native scene its real restoration lifecycle.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: Self.timeout))
        app.activate()
        assertConnections(app, current: "Travel Mac", other: "Studio Mac")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: Self.timeout))
        app.terminate()
        app.launch()
        openSettings(app)
        assertConnections(app, current: "Studio Mac", other: "Travel Mac")
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
        let manual = app.staticTexts["manual.title"]
        XCTAssertTrue(manual.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["manual.connect"].exists)
        app.buttons["connection-sheet.close"].tap()
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
        capture(app, named: "Settings-Acknowledgements")
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
        assertScrollingLogOffAndRevealActions(app)
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
    private func assertScrollingLogOffAndRevealActions(_ app: XCUIApplication) {
        let close = app.buttons["settings.close"]
        let initialCloseY = close.frame.minY
        for title in ["Manual Connection", "Acknowledgements", "Export logs"] {
            let button = app.buttons[title]
            reveal(button, in: app)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        let logOff = app.buttons["Log Off"]
        reveal(logOff, in: app)
        XCTAssertGreaterThanOrEqual(logOff.frame.height, 44)
        XCTAssertLessThanOrEqual(
            app.buttons["Export logs"].frame.maxY,
            logOff.frame.minY,
            "Log Off must follow the support actions without overlap"
        )
        if !close.isHittable || close.frame.minY < initialCloseY - 1 {
            let lowerFrame = logOff.frame
            scrollToTop(app)
            XCTAssertTrue(
                !logOff.isHittable || logOff.frame.minY > lowerFrame.minY + 1,
                "Log Off must move with Settings content, not stay pinned to the viewport"
            )
            reveal(logOff, in: app)
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
        let scrollView = app.scrollViews.firstMatch
        let viewport = scrollView.frame.intersection(app.frame)
        for _ in 0..<Self.maximumSwipes where !element.isHittable || !viewport.contains(element.frame) {
            scrollView.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
        XCTAssertTrue(viewport.contains(element.frame), "The full action must be reachable inside the Settings viewport")
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
