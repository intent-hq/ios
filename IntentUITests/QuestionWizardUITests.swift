import XCTest

/// Exercises the real workspace wizard and demo RPC response, not a layout toggle.
nonisolated final class QuestionWizardUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

    @MainActor
    func testSelectionFreeTextAndMultiSelectSurviveBackThenSend() throws {
        let app = try openQuestions()
        tap(app.buttons["question.answer"])
        tap(app.buttons["question.option.0"])
        XCTAssertTrue(app.staticTexts["Question Two"].waitForExistence(timeout: Self.timeout))
        tapOption(0, in: app)
        tapOption(1, in: app)
        tap(app.buttons["question.back"])
        XCTAssertEqual(app.buttons["question.option.0"].value as? String, "Selected")

        tap(app.buttons["question.actions"])
        tap(app.buttons["Write your own answer"])
        let editor = app.textViews["Type your own answer…"].firstMatch
        tap(editor)
        editor.typeText("Only after review")
        if !app.buttons["question.next"].isHittable {
            app.scrollViews.containing(.textView, identifier: "Type your own answer…").firstMatch.swipeUp()
        }
        tap(app.buttons["question.next"])
        XCTAssertTrue(app.staticTexts["Question Two"].waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(app.buttons["question.option.0"].value as? String, "Selected")
        XCTAssertEqual(app.buttons["question.option.1"].value as? String, "Selected")
        tap(app.buttons["question.next"])

        assertSentMessage(in: app, contains: [
            "A: Yes, confirmed, (Other) Only after review",
            "A: Local tests, Hosted benchmark"
        ])
        XCTAssertTrue(app.buttons["question.next"].waitForNonExistence(timeout: Self.timeout))
    }

    @MainActor
    func testSkipClearsAnEarlierSelection() throws {
        let app = try openQuestions()
        tap(app.buttons["question.answer"])
        tap(app.buttons["question.option.0"])
        XCTAssertTrue(app.staticTexts["Question Two"].waitForExistence(timeout: Self.timeout))
        tap(app.buttons["question.back"])
        tap(app.buttons["question.skip"])
        XCTAssertTrue(app.staticTexts["Question Two"].waitForExistence(timeout: Self.timeout))
        tap(app.buttons["question.skip"])
        assertSentMessage(in: app, contains: [
            "Q: Can I access the repository?\nA: (skipped)",
            "Q: Which checks should I run?\nA: (skipped)"
        ])
    }

    @MainActor
    func testDismissRequiresConfirmationAndCancelPreservesQuestions() throws {
        let app = try openQuestions()
        tap(app.buttons["question.dismiss"])
        tap(app.buttons["Cancel"])
        XCTAssertTrue(app.buttons["question.answer"].waitForExistence(timeout: Self.timeout))
        tap(app.buttons["question.answer"])
        XCTAssertTrue(app.staticTexts["Question One"].waitForExistence(timeout: Self.timeout))
        tap(app.buttons["question.actions"])
        tap(app.buttons["Dismiss questions"])
        tap(app.buttons["Dismiss questions"])
        XCTAssertTrue(app.buttons["question.actions"].waitForNonExistence(timeout: Self.timeout))
        XCTAssertFalse(app.buttons["question.answer"].exists)
        XCTAssertTrue(app.textViews["Message…"].firstMatch.waitForExistence(timeout: Self.timeout))
    }

    @MainActor
    private func openQuestions() throws -> XCUIApplication {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Workspace phone presentation")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-design-scenario=question-flow"]
        app.launch()
        tap(app.staticTexts["Workspace agent design"].firstMatch)
        tap(app.staticTexts["Continue Spec Writer"].firstMatch)
        let questionControl = app.buttons.matching(
            NSPredicate(format: "identifier IN %@", ["question.answer", "question.actions"])
        ).firstMatch
        XCTAssertTrue(questionControl.waitForExistence(timeout: Self.timeout))
        if !app.buttons["question.answer"].exists {
            tap(app.buttons["question.actions"])
            tap(app.buttons["Collapse questions"])
        }
        XCTAssertTrue(app.buttons["question.answer"].waitForExistence(timeout: Self.timeout))
        return app
    }

    @MainActor
    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: Self.timeout))
        element.tap()
    }

    @MainActor
    private func tapOption(_ index: Int, in app: XCUIApplication) {
        let option = app.buttons["question.option.\(index)"]
        XCTAssertTrue(option.waitForExistence(timeout: Self.timeout))
        if !option.isHittable {
            app.scrollViews.containing(.button, identifier: "question.option.0").firstMatch.swipeLeft()
        }
        tap(option)
    }

    @MainActor
    private func assertSentMessage(in app: XCUIApplication, contains fragments: [String]) {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: fragments.map { fragment in
            NSPredicate(format: "label CONTAINS %@", fragment)
        })
        let sent = app.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: Self.timeout), "Submitted answers were not echoed by the demo RPC")
    }
}
