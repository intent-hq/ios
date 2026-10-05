import XCTest

/// Exercises the real workspace wizard and demo RPC response, not a layout toggle.
nonisolated final class QuestionWizardUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

    @MainActor
    func testHorizontalCardsKeepReferenceHeightAcrossSelectionAndBack() throws {
        let app = try openQuestions(scenario: "question-cards", collapsed: false)
        tap(app.textViews["Type your own answer…"].firstMatch)
        tap(app.buttons["question.skip"])
        XCTAssertTrue(app.staticTexts["Short answers"].waitForExistence(timeout: Self.timeout))
        let first = app.buttons["question.option.0"]
        let second = app.buttons["question.option.1"]
        XCTAssertTrue(second.waitForExistence(timeout: Self.timeout))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "question-cards-compact-reference"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        assertReferenceCards(first, second)

        let carousel = app.scrollViews.containing(.button, identifier: "question.option.0").firstMatch
        carousel.swipeLeft()
        let third = app.buttons["question.option.2"]
        XCTAssertTrue(third.isHittable)
        XCTAssertEqual(third.frame.height, 120, accuracy: 1, "Missing descriptions must not shrink cards")
        carousel.swipeRight()
        tap(first)
        XCTAssertTrue(app.staticTexts["Short answers"].exists, "Selecting must wait for explicit Next")
        XCTAssertEqual(first.value as? String, "Selected")
        assertReferenceCards(first, second)
        tap(app.buttons["question.next"])
        XCTAssertTrue(app.staticTexts["Detailed answers"].waitForExistence(timeout: Self.timeout))
        tap(app.buttons["question.back"])
        XCTAssertTrue(app.staticTexts["Short answers"].waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(first.value as? String, "Selected")
        assertReferenceCards(first, second)
    }

    @MainActor
    func testOversizedHorizontalAnswerUsesReadableVerticalFallback() throws {
        let app = try openQuestions(scenario: "question-cards", collapsed: false)
        tap(app.textViews["Type your own answer…"].firstMatch)
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
        XCTAssertEqual(first.frame.height, 120, accuracy: 1)
        XCTAssertEqual(second.frame.height, 120, accuracy: 1)
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
        // Native modal snapshots may retain the presenting view's elements.
        // Existence alone does not indicate that a person can interact with them.
        for identifier in ["question.answer", "question.dismiss", "conversation.back", "conversation.actions.open"] {
            XCTAssertFalse(app.buttons[identifier].isHittable, "The native modal must block \(identifier)")
        }
        XCTAssertFalse(app.scrollViews["transcript.scrollView"].isHittable)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.4))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.4)))
        XCTAssertTrue(first.isHittable, "Backdrop taps and the back gesture must not dismiss unanswered questions")
        XCTAssertLessThan(first.frame.maxY, second.frame.minY)
        XCTAssertEqual(first.value as? String, "Selected")
        tap(app.textViews["Type your own answer…"].firstMatch)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Self.timeout))
        XCTAssertLessThan(first.frame.maxY, second.frame.minY, "The two-answer reference must also fit vertically above the keyboard")
        XCTAssertTrue(app.buttons["question.next"].isHittable)
        let keyboardScreenshot = XCTAttachment(screenshot: app.screenshot())
        keyboardScreenshot.name = "questions-vertical-keyboard"
        keyboardScreenshot.lifetime = .keepAlways
        add(keyboardScreenshot)
    }

    @MainActor
    func testSelectionFreeTextAndMultiSelectSurviveBackThenSend() throws {
        let app = try openQuestions()
        tap(app.buttons["question.answer"])
        XCTAssertFalse(app.buttons["question.next"].isEnabled)
        tap(app.buttons["question.option.0"])
        XCTAssertTrue(app.staticTexts["Question One"].exists)
        tap(app.buttons["question.next"])
        XCTAssertTrue(app.staticTexts["Question Two"].waitForExistence(timeout: Self.timeout))
        tapOption(0, in: app)
        tapOption(1, in: app)
        tap(app.buttons["question.back"])
        XCTAssertEqual(app.buttons["question.option.0"].value as? String, "Selected")

        tap(app.buttons["Write your own answer"])
        let editor = app.textViews["Type your own answer…"].firstMatch
        tap(editor)
        editor.typeText("Only after review")
        XCTAssertEqual(editor.value as? String, "Only after review")
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
        tap(app.buttons["question.next"])
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
        tap(app.buttons["question.dismiss"])
        XCTAssertTrue(confirmation.waitForExistence(timeout: Self.timeout))
        tap(confirmation.buttons["Dismiss questions"])
        XCTAssertTrue(app.buttons["question.answer"].waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(app.textViews["composer.textView"].firstMatch.waitForExistence(timeout: Self.timeout))
    }

    /// Unlike hosted component tests, this exercises native keyboard avoidance
    /// and draft isolation while the floating panel blocks the conversation.
    @MainActor
    func testExpandedQuestionsKeepDraftWithoutSendingAboveKeyboard() throws {
        let app = try openQuestions()
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
        XCTAssertFalse(send.isEnabled, "Pending questions require an explicit answer or dismissal")
        tap(app.buttons["question.answer"])
        let answer = app.textViews["Type your own answer…"].firstMatch
        tap(answer)
        answer.typeText("A separate\nanswer")
        XCTAssertEqual(answer.value as? String, "A separate\nanswer")
        XCTAssertFalse(send.isHittable, "The ordinary composer must not be interactive beneath the modal")
        XCTAssertFalse(composer.isHittable)
        XCTAssertLessThanOrEqual(answer.frame.maxY, keyboard.frame.minY)
        let next = app.buttons["question.next"]
        let questionScroll = app.scrollViews.containing(.button, identifier: "question.option.0").firstMatch
        if questionScroll.exists, !questionScroll.frame.contains(next.frame) {
            questionScroll.swipeUp()
        }
        for identifier in ["question.back", "question.skip", "question.next"] {
            let button = app.buttons[identifier]
            XCTAssertLessThanOrEqual(button.frame.maxY, answer.frame.minY, "The complete footer must stay above the editor")
            if questionScroll.exists {
                XCTAssertTrue(questionScroll.frame.contains(button.frame), "The complete footer must be reachable in the scroll viewport")
            }
        }
        XCTAssertTrue(next.isHittable)
        XCTAssertTrue(app.buttons["question.skip"].isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "questions-floating-keyboard"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        tap(app.buttons["question.next"])
        tap(app.buttons["question.skip"])
        assertSentMessage(in: app, contains: ["A: (Other) A separate\nanswer", "A: (skipped)"])
        XCTAssertTrue(composer.waitForExistence(timeout: Self.timeout))
        tap(composer)
        XCTAssertLessThanOrEqual(composer.frame.maxY, keyboard.frame.minY)
        XCTAssertGreaterThan(app.scrollViews["transcript.scrollView"].frame.height, 0)
        XCTAssertEqual(composer.value as? String, draft)
        XCTAssertTrue(send.isEnabled, "Answering releases the ordinary-message send hold")
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

    @MainActor
    private func openQuestions(scenario: String = "question-flow", collapsed: Bool = true) throws -> XCUIApplication {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Workspace phone presentation")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-design-scenario=\(scenario)"]
        app.launch()
        tap(app.staticTexts["Workspace agent design"].firstMatch)
        tap(app.staticTexts["Continue Spec Writer"].firstMatch)
        XCTAssertTrue(app.buttons["question.answer"].waitForExistence(timeout: Self.timeout))
        if !collapsed { tap(app.buttons["question.answer"]) }
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
