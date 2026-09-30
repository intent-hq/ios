import XCTest

/// Exercises the real workspace wizard and demo RPC response, not a layout toggle.
nonisolated final class QuestionWizardUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

    @MainActor
    func testHorizontalCardsKeepReferenceHeightAcrossContentAndSelection() throws {
        let app = try openQuestions(scenario: "question-cards", collapsed: false)
        let first = app.buttons["question.option.0"]
        let second = app.buttons["question.option.1"]
        XCTAssertTrue(second.waitForExistence(timeout: Self.timeout))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "question-cards-mixed-reference"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        assertReferenceCards(first, second)

        let carousel = app.scrollViews.containing(.button, identifier: "question.option.0").firstMatch
        carousel.swipeLeft()
        let third = app.buttons["question.option.2"]
        XCTAssertTrue(third.isHittable)
        XCTAssertEqual(third.frame.height, 166, accuracy: 1, "Missing descriptions must not shrink cards")
        carousel.swipeRight()
        tap(first)
        XCTAssertTrue(app.staticTexts["Short answers"].waitForExistence(timeout: Self.timeout))
        assertReferenceCards(first, second)
        tap(first)
        XCTAssertEqual(first.value as? String, "Selected")
        assertReferenceCards(first, second)
        tap(app.buttons["question.back"])
        XCTAssertTrue(app.staticTexts["Publish verified changes"].waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(first.value as? String, "Selected")
        assertReferenceCards(first, second)
    }

    @MainActor
    func testOversizedHorizontalAnswerUsesReadableVerticalFallback() throws {
        let app = try openQuestions(scenario: "question-cards", collapsed: false)
        tap(app.buttons["question.skip"])
        XCTAssertTrue(app.staticTexts["Short answers"].waitForExistence(timeout: Self.timeout))
        tap(app.buttons["question.skip"])
        XCTAssertTrue(app.staticTexts["Detailed answers"].waitForExistence(timeout: Self.timeout))
        let first = app.buttons["question.option.0"]
        let second = app.buttons["question.option.1"]
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "question-cards-overflow"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertLessThan(first.frame.maxY, second.frame.minY)
        XCTAssertEqual(first.frame.minX, second.frame.minX, accuracy: 1)
        let shortHeight = first.frame.height
        let scroll = app.scrollViews.containing(.button, identifier: "question.option.0").firstMatch
        scroll.swipeUp()
        let last = app.buttons["question.option.3"]
        XCTAssertTrue(last.isHittable)
        XCTAssertGreaterThan(last.frame.height, shortHeight, "The vertical fallback must retain natural text heights")
        tap(last)
        XCTAssertEqual(last.value as? String, "Selected")
        if !app.buttons["question.next"].isHittable { scroll.swipeUp() }
        tap(app.buttons["question.next"])
        assertSentMessage(in: app, contains: ["A: Full review"])
    }

    @MainActor
    private func assertReferenceCards(_ first: XCUIElement, _ second: XCUIElement) {
        XCTAssertGreaterThan(second.frame.minX, first.frame.minX, "This must exercise the horizontal carousel")
        XCTAssertEqual(first.frame.minY, second.frame.minY, accuracy: 1)
        XCTAssertEqual(first.frame.height, 166, accuracy: 1)
        XCTAssertEqual(second.frame.height, 166, accuracy: 1)
    }

    @MainActor
    func testWorkspaceQuestionsStackAtDefaultPhoneSize() throws {
        let app = try openQuestions(scenario: "questions", collapsed: false)
        let first = app.buttons["question.option.0"]
        let second = app.buttons["question.option.1"]
        XCTAssertTrue(second.waitForExistence(timeout: Self.timeout))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "questions-default-phone"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertLessThan(first.frame.maxY, second.frame.minY, "Both answers must stack in the real phone host")
        XCTAssertEqual(first.frame.minX, second.frame.minX)
        XCTAssertTrue(first.isHittable)
        XCTAssertTrue(second.isHittable)
        tap(first)
        XCTAssertEqual(first.value as? String, "Selected")
        tap(app.buttons["question.actions"])
        tap(app.buttons["Collapse questions"])
        tap(app.buttons["question.answer"])
        XCTAssertTrue(first.waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(first.value as? String, "Selected")

        let stacked = XCTNSPredicateExpectation(
            predicate: Self.stackedAnswersPredicate,
            object: [first, second]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [stacked], timeout: Self.timeout), .completed)
        XCTAssertLessThan(first.frame.maxY, second.frame.minY)
        XCTAssertEqual(first.value as? String, "Selected")
    }

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
        XCTAssertEqual(editor.value as? String, "Only after review")
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
        let confirmation = app.sheets["Dismiss questions?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(confirmation.buttons["Dismiss questions"].isHittable)
        let cancel = confirmation.buttons["Cancel"]
        if cancel.exists {
            tap(cancel)
        } else {
            cancelQuestionPopover(in: app)
        }
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["question.answer"].waitForExistence(timeout: Self.timeout))
        tap(app.buttons["question.answer"])
        XCTAssertTrue(app.staticTexts["Question One"].waitForExistence(timeout: Self.timeout))
        tap(app.buttons["question.actions"])
        tap(app.buttons["Dismiss questions"])
        XCTAssertTrue(confirmation.waitForExistence(timeout: Self.timeout))
        tap(confirmation.buttons["Dismiss questions"])
        XCTAssertTrue(app.buttons["question.actions"].waitForNonExistence(timeout: Self.timeout))
        XCTAssertFalse(app.buttons["question.answer"].exists)
        XCTAssertTrue(app.textViews["composer.textView"].firstMatch.waitForExistence(timeout: Self.timeout))
    }

    /// Unlike hosted component tests, this exercises native keyboard avoidance
    /// and the host's send hold while a draft coexists with expanded questions.
    @MainActor
    func testExpandedQuestionsKeepDraftWithoutSendingAboveKeyboard() throws {
        let app = try openQuestions()
        tap(app.buttons["question.answer"])
        let composer = app.textViews["composer.textView"]
        tap(composer)
        let draft = "Keep this draft\nfor later"
        composer.typeText(draft)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(keyboard.isHittable)
        XCTAssertEqual(composer.value as? String, draft, "Return remains a newline, not a question-bypassing submit")
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.exists)
        XCTAssertFalse(send.isEnabled, "Expanded questions retain the old composer send hold")
        XCTAssertLessThanOrEqual(composer.frame.maxY, keyboard.frame.minY)
        XCTAssertGreaterThan(app.scrollViews["transcript.scrollView"].frame.height, 0)
        XCTAssertTrue(app.buttons["question.actions"].isHittable)
        tap(app.buttons["question.actions"])
        tap(app.buttons["Collapse questions"])
        XCTAssertTrue(app.buttons["question.answer"].waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(composer.value as? String, draft)
        XCTAssertTrue(send.isEnabled, "Explicit collapse keeps the existing ordinary-message escape hatch")
    }

    @MainActor
    private func cancelQuestionPopover(in app: XCUIApplication) {
        let popover = app.popovers.containing(.sheet, identifier: "Dismiss questions?").element
        let dismissRegion = app.otherElements["PopoverDismissRegion"]
        XCTAssertTrue(popover.exists)
        XCTAssertTrue(dismissRegion.exists)
        XCTAssertTrue(dismissRegion.isHittable)

        // The native modal dismissal region intercepts the tap, not the app beneath it.
        // Its frame covers the popover too, so avoid its center and use the exposed left strip.
        let regionFrame = dismissRegion.frame.intersection(app.frame)
        let popoverFrame = popover.frame
        XCTAssertGreaterThan(popoverFrame.minX, regionFrame.minX)
        let point = CGPoint(x: (regionFrame.minX + popoverFrame.minX) / 2, y: popoverFrame.midY)
        XCTAssertTrue(regionFrame.contains(point))
        XCTAssertFalse(popoverFrame.contains(point), "Cancellation must not tap a confirmation action")
        dismissRegion
            .coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(
                dx: point.x - dismissRegion.frame.minX,
                dy: point.y - dismissRegion.frame.minY
            ))
            .tap()
        XCTAssertTrue(dismissRegion.waitForNonExistence(timeout: Self.timeout))
    }

    private static var stackedAnswersPredicate: NSPredicate {
        NSPredicate { object, _ in
            guard let answers = object as? [XCUIElement], answers.count == 2 else { return false }
            return answers[0].frame.maxY < answers[1].frame.minY
                && answers[0].frame.minX == answers[1].frame.minX
        }
    }

    @MainActor
    private func openQuestions(scenario: String = "question-flow", collapsed: Bool = true) throws -> XCUIApplication {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Workspace phone presentation")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-design-scenario=\(scenario)"]
        app.launch()
        tap(app.staticTexts["Workspace agent design"].firstMatch)
        tap(app.staticTexts["Continue Spec Writer"].firstMatch)
        let questionControl = app.buttons.matching(
            NSPredicate(format: "identifier IN %@", ["question.answer", "question.actions"])
        ).firstMatch
        XCTAssertTrue(questionControl.waitForExistence(timeout: Self.timeout))
        if !collapsed { return app }
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
