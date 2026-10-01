import XCTest

/// Exercises the real Settings routes with ephemeral saved machines and no daemon.
nonisolated final class SettingsUITests: XCTestCase {
    private static let timeout: TimeInterval = 15
    private static let maximumSwipes = 12

    @MainActor
    func testSettingsHasNoAppearanceControlsWithLightDarkScreenshots() {
        for appearance in ["Light", "Dark"] {
            let app = launch(themePreference: appearance.lowercased())
            openSettings(app)
            let settings = app.scrollViews["settings.scroll"]
            XCTAssertTrue(settings.staticTexts["PAIR NEW"].exists)
            XCTAssertFalse(settings.staticTexts["CONNECTIONS"].exists)
            for name in ["Studio Mac", "Travel Mac"] {
                XCTAssertFalse(settings.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch.exists)
            }
            XCTAssertFalse(settings.staticTexts["APPEARANCE"].exists)
            for choice in ["Light", "Dark", "System"] {
                XCTAssertFalse(settings.buttons[choice].exists, "Theme controls belong only in the Home menu")
            }
            capture(app, named: "Settings-" + appearance)
            assertScrollingLogOffAndRevealActions(app)
            capture(app, named: "Settings-" + appearance + "-Actions")
            scrollToTop(app)
            captureWorkspaceSurfaces(app, appearance: appearance)
            app.terminate()
        }
    }

    @MainActor
    func testSavedConnectionSelectionUsesWindowRouting() {
        let app = launch()
        openConnections(app)
        assertConnections(app, current: "Studio Mac", other: "Travel Mac")
        card(app, named: "Studio Mac").tap()
        XCTAssertTrue(app.buttons["intent.menu.open"].waitForExistence(timeout: Self.timeout))
        openConnections(app)
        card(app, named: "Travel Mac").tap()
        XCTAssertTrue(app.buttons["intent.menu.open"].waitForExistence(timeout: Self.timeout))
        openConnections(app)
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
        openConnections(app)
        assertConnections(app, current: "Studio Mac", other: "Travel Mac")
        card(app, named: "Travel Mac").tap()
        XCTAssertTrue(app.buttons["intent.menu.open"].waitForExistence(timeout: Self.timeout))
        openConnections(app)
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
        XCTAssertTrue(app.staticTexts["PAIR NEW"].exists)
        XCTAssertTrue(app.buttons["settings.close"].isHittable)
    }

    @MainActor
    func testLargeTextKeepsPairingSupportAndLogOffCancellationReachable() {
        let app = launch(largeText: true, themePreference: "light")
        openSettings(app)
        capture(app, named: "Settings-LargeText-Top")
        assertScrollingLogOffAndRevealActions(app)
        capture(app, named: "Settings-LargeText-Actions")
        app.buttons["Log Off"].tap()
        let confirmation = app.staticTexts["log-off.title"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: Self.timeout))
        capture(app, named: "Log-Off-Light-LargeText")
        app.buttons["log-off.cancel"].tap()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: Self.timeout))
        scrollToTop(app)
        XCTAssertTrue(app.staticTexts["PAIR NEW"].exists)
    }

    @MainActor
    func testLogOffRequiresConfirmationAndCanBeCancelled() {
        let app = launch()
        openSettings(app)
        let logOff = app.buttons["Log Off"]
        reveal(logOff, in: app)
        logOff.tap()
        let confirmation = app.staticTexts["log-off.title"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: Self.timeout))
        app.buttons["log-off.cancel"].tap()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: Self.timeout))
        reveal(logOff, in: app)
        logOff.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: Self.timeout))
        app.buttons["connection-sheet.close"].tap()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: Self.timeout))
        scrollToTop(app)
        XCTAssertTrue(app.staticTexts["PAIR NEW"].exists)
    }

    @MainActor
    func testConfirmedLogOffForgetsOnlyTheCurrentConnection() {
        let app = launch(themePreference: "dark")
        openSettings(app)
        let logOff = app.buttons["Log Off"]
        reveal(logOff, in: app)
        logOff.tap()
        let confirmation = app.staticTexts["log-off.title"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: Self.timeout))
        capture(app, named: "Log-Off-Dark")
        app.buttons["log-off.confirm"].tap()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: Self.timeout))
        app.openHomeAction("connections")
        XCTAssertTrue(app.staticTexts["saved-connections.title"].waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Travel Mac")).firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Studio Mac")).firstMatch.exists)
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
    private func launch(largeText: Bool = false, themePreference: String = "system") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
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
        XCTAssertTrue(app.buttons["settings.close"].waitForExistence(timeout: Self.timeout))
    }

    @MainActor
    private func openConnections(_ app: XCUIApplication) {
        app.openHomeAction("connections")
        XCTAssertTrue(app.staticTexts["saved-connections.title"].waitForExistence(timeout: Self.timeout))
    }

    @MainActor
    private func card(_ app: XCUIApplication, named name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "saved-connection.", name)).firstMatch
    }

    @MainActor
    private func assertConnections(_ app: XCUIApplication, current: String, other: String) {
        let selected = card(app, named: current)
        XCTAssertTrue(selected.waitForExistence(timeout: Self.timeout))
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
    private func captureWorkspaceSurfaces(_ app: XCUIApplication, appearance: String) {
        app.buttons["settings.close"].tap()
        let options = app.buttons["intent.menu.open"]
        XCTAssertTrue(options.waitForExistence(timeout: Self.timeout))
        options.tap()
        XCTAssertTrue(app.buttons["intent.menu.assistant"].waitForExistence(timeout: Self.timeout))
        capture(app, named: "Workspace-Menu-" + appearance)
        app.revealHomeAction("connections").tap()
        let title = app.staticTexts["saved-connections.title"]
        XCTAssertTrue(title.waitForExistence(timeout: Self.timeout))
        capture(app, named: "Connections-" + appearance)
        app.buttons["connection-sheet.close"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: Self.timeout))
        openSettings(app)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
