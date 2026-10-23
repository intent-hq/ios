import XCTest

nonisolated final class SettingsAgentUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

    @MainActor
    func testGlobalInstructionsSaveAndReopenInBothAppearances() {
        for appearance in ["Light", "Dark"] {
            let app = launch(appearance: appearance)
            openInstructions(app)
            capture(app, named: "Global-Instructions-" + appearance)
            let enabled = app.switches["settings.instructions.enabled"]
            XCTAssertEqual(enabled.value as? String, "1")
            enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: enabled)
            XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: Self.timeout), .completed)
            let editor = app.textViews["settings.instructions.content"]
            editor.tap()
            editor.typeText("\nKeep responses concise.")
            let save = app.buttons["settings.instructions.save"]
            XCTAssertTrue(save.isEnabled)
            save.tap()
            let saved = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == 'Save' AND enabled == false"), object: save
            )
            XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: Self.timeout), .completed)
            app.buttons["settings.instructions.close"].tap()
            XCTAssertTrue(editor.waitForNonExistence(timeout: Self.timeout))
            openInstructions(app, fromHome: false)
            XCTAssertEqual((editor.value as? String)?.contains("Keep responses concise."), true)
            XCTAssertEqual(enabled.value as? String, "0")
            XCTAssertFalse(save.isEnabled)
            capture(app, named: "Global-Instructions-Saved-" + appearance)
            app.terminate()
        }
    }

    @MainActor
    func testProviderEnablementPersistsAfterRefreshInBothAppearances() {
        for appearance in ["Light", "Dark"] {
            let app = launch(appearance: appearance)
            app.openHomeAction("settings")
            XCTAssertTrue(app.buttons["settings.close"].waitForExistence(timeout: Self.timeout))
            capture(app, named: "Settings-Agents-" + appearance)
            app.buttons["settings.providers"].tap()
            let toggle = app.switches["settings.providers.codex.enabled"]
            XCTAssertTrue(toggle.waitForExistence(timeout: Self.timeout))
            capture(app, named: "Providers-" + appearance)
            toggle.tap()
            let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: toggle)
            XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: Self.timeout), .completed)
            app.buttons["settings.providers.refresh"].tap()
            let refreshed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: toggle)
            XCTAssertEqual(XCTWaiter.wait(for: [refreshed], timeout: Self.timeout), .completed)
            XCTAssertEqual(toggle.value as? String, "0")
            capture(app, named: "Providers-Disabled-" + appearance)
            app.terminate()
        }
    }

    @MainActor
    func testFailedSaveRetainsDraftAndCloseRequiresDiscard() {
        let app = launch(appearance: "Light", failure: true)
        openInstructions(app)
        let editor = app.textViews["settings.instructions.content"]
        editor.tap()
        editor.typeText("\nKeep my draft.")
        app.buttons["settings.instructions.save"].tap()
        XCTAssertTrue(app.staticTexts["settings.instructions.error"].waitForExistence(timeout: Self.timeout))
        XCTAssertEqual((editor.value as? String)?.contains("Keep my draft."), true)
        capture(app, named: "Global-Instructions-Save-Failure")
        app.buttons["settings.instructions.close"].tap()
        let keepEditing = app.buttons["Keep editing"]
        XCTAssertTrue(keepEditing.waitForExistence(timeout: Self.timeout))
        capture(app, named: "Global-Instructions-Discard-Confirmation")
        keepEditing.tap()
        XCTAssertEqual((editor.value as? String)?.contains("Keep my draft."), true)
        app.buttons["settings.instructions.close"].tap()
        app.buttons["Discard changes"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: Self.timeout))
    }

    @MainActor
    private func launch(appearance: String, failure: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-settings", "-appThemePreference", appearance.lowercased()]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if failure { app.launchArguments += ["--demo-settings-save-failure"] }
        app.launch()
        addTeardownBlock { @MainActor in
            guard app.state == .runningForeground else { return }
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Settings-Agents-Final"
            attachment.lifetime = .keepAlways
            self.add(attachment)
        }
        return app
    }

    @MainActor
    private func openInstructions(_ app: XCUIApplication, fromHome: Bool = true) {
        if fromHome {
            app.openHomeAction("settings")
            XCTAssertTrue(app.buttons["settings.close"].waitForExistence(timeout: Self.timeout))
        }
        let instructions = app.buttons["settings.instructions"]
        XCTAssertTrue(instructions.waitForExistence(timeout: Self.timeout))
        instructions.tap()
        XCTAssertTrue(app.textViews["settings.instructions.content"].waitForExistence(timeout: Self.timeout))
    }

    @MainActor
    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
