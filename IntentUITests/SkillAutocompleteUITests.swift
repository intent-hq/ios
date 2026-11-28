import XCTest

nonisolated final class SkillAutocompleteUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

    @MainActor
    func testSkillSuggestionsFilterInsertAndSendInBothThemes() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let editor = app.textViews["composer.textView"]
            editor.tap()
            editor.typeText("Please /")
            let review = app.buttons["composer.skill.code-review"]
            XCTAssertTrue(review.appears(timeout: Self.timeout))
            capture(app, name: "skill-suggestions-\(appearance)")
            editor.typeText("device")
            let build = app.buttons["composer.skill.ios-device-build"]
            XCTAssertTrue(build.appears(timeout: Self.timeout))
            XCTAssertFalse(review.exists)
            build.tap()
            XCTAssertEqual(editor.value as? String, "Please /ios-device-build ")
            XCTAssertTrue(app.keyboards.firstMatch.exists)
            XCTAssertEqual(editor.value(forKey: "hasKeyboardFocus") as? Bool, true)
            editor.typeText("on my phone")
            XCTAssertEqual(editor.value as? String, "Please /ios-device-build on my phone")
            XCTAssertFalse(app.buttons["composer.skill.ios-device-build"].exists)
            capture(app, name: "skill-inserted-\(appearance)")
            app.buttons["composer.send"].tap()
            XCTAssertTrue(app.buttons["composer.stop"].appears(timeout: Self.timeout))
            XCTAssertEqual(editor.value as? String, "")
            let sent = app.scrollViews["transcript.scrollView"].staticTexts
                .matching(NSPredicate(format: "label CONTAINS %@", "Please /ios-device-build on my phone")).firstMatch
            XCTAssertTrue(sent.appears(timeout: Self.timeout))
            app.terminate()
        }
    }

    @MainActor
    func testNoMatchCanRecoverAndPathsDoNotTriggerSuggestions() {
        continueAfterFailure = false
        let app = launch(appearance: "light")
        let editor = app.textViews["composer.textView"]
        editor.tap()
        editor.typeText("https://example.com /usr/bin /zzzz")
        XCTAssertTrue(app.staticTexts["No matching skills"].appears(timeout: Self.timeout))
        editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
        XCTAssertTrue(app.buttons["composer.skill.code-review"].appears(timeout: Self.timeout))
        editor.typeText("usr/bin")
        XCTAssertTrue(app.buttons["composer.skill.code-review"].disappears(timeout: Self.timeout))
        XCTAssertFalse(app.staticTexts["No matching skills"].exists)
    }

    @MainActor
    func testLongPressShowsDescriptionAndUseKeepsKeyboard() {
        continueAfterFailure = false
        let app = launch(appearance: "light")
        let editor = app.textViews["composer.textView"]
        editor.tap()
        editor.typeText("/")
        let review = app.buttons["composer.skill.code-review"]
        XCTAssertTrue(review.appears(timeout: Self.timeout))
        review.press(forDuration: 1)
        let description = app.staticTexts["Review changes for bugs, regressions, and missing tests."]
        XCTAssertTrue(description.appears(timeout: Self.timeout))
        capture(app, name: "skill-description-preview")
        app.buttons["Use"].tap()
        XCTAssertTrue(description.disappears(timeout: Self.timeout))
        XCTAssertEqual(editor.value as? String, "/code-review ")
        XCTAssertTrue(app.keyboards.firstMatch.appears(timeout: Self.timeout))
    }

    @MainActor
    private func launch(appearance: String) -> XCUIApplication {
        let app = XCUIApplication.intent()
        app.launchArguments = ["--demo-data", "--demo-design-scenario=composer", "-appThemePreference", appearance]
        app.launch()
        let workspace = app.staticTexts["Workspace agent design"].firstMatch
        XCTAssertTrue(workspace.appears(timeout: Self.timeout))
        workspace.tap()
        let agent = app.staticTexts["Continue Spec Writer"].firstMatch
        XCTAssertTrue(agent.appears(timeout: Self.timeout))
        agent.tap()
        XCTAssertTrue(app.textViews["composer.textView"].appears(timeout: Self.timeout))
        return app
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
