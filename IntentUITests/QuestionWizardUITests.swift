import XCTest

/// Exercises the real workspace wizard and demo RPC response, not a layout toggle.
nonisolated final class QuestionWizardUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

    @MainActor
    func testAnswersStayStackedAcrossKeyboardSelectionAndBack() throws {
        let app = try openQuestions(scenario: "question-cards", collapsed: false)
        tap(app.buttons["question.skip"])
        XCTAssertTrue(app.staticTexts["Short answers"].waitForExistence(timeout: Self.timeout))
        let first = app.buttons["question.option.0"]
        let second = app.buttons["question.option.1"]
        XCTAssertTrue(second.waitForExistence(timeout: Self.timeout))
        assertStackedCards(first, second)
        tap(first)
        XCTAssertTrue(app.staticTexts["Short answers"].exists, "Selecting must wait for explicit Next")
        XCTAssertEqual(first.value as? String, "Selected")
        assertStackedCards(first, second)

        tap(answerField(in: app))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Self.timeout))
        assertStackedCards(first, second)
        attachScreenshot("question-cards-stacked-keyboard", in: app)
        tapQuestionAction("question.next", in: app)
        XCTAssertTrue(app.staticTexts["Detailed answers"].waitForExistence(timeout: Self.timeout))
        tapQuestionAction("question.back", in: app)
        XCTAssertTrue(app.staticTexts["Short answers"].waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(first.value as? String, "Selected")
        XCTAssertTrue(app.keyboards.firstMatch.isHittable)
        assertStackedCards(first, second)
    }

    @MainActor
    func testLongAnswersScrollVerticallyWithoutClipping() throws {
        let app = try openQuestions(scenario: "question-cards", collapsed: false)
        tapQuestionAction("question.skip", in: app)
        XCTAssertTrue(app.staticTexts["Short answers"].waitForExistence(timeout: Self.timeout))
        tapQuestionAction("question.skip", in: app)
        XCTAssertTrue(app.staticTexts["Detailed answers"].waitForExistence(timeout: Self.timeout))
        let first = app.buttons["question.option.0"]
        let second = app.buttons["question.option.1"]
        XCTAssertLessThan(first.frame.maxY, second.frame.minY)
        XCTAssertEqual(first.frame.minX, second.frame.minX, accuracy: 1)
        let shortHeight = first.frame.height

        let editor = answerField(in: app)
        tap(editor)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Self.timeout))
        let scroll = app.scrollViews.containing(.button, identifier: "question.option.0").firstMatch
        let send = app.buttons["question.next"]
        let header = app.staticTexts["Detailed answers"]
        XCTAssertTrue(scroll.frame.contains(header.frame), "Focusing the editor must keep the question header fully visible")
        XCTAssertEqual(header.frame.minY, scroll.frame.minY + 24, accuracy: 1, "The panel must stay at its top padding")
        XCTAssertLessThanOrEqual(scroll.frame.maxY, editor.frame.minY)
        attachScreenshot("question-cards-focused-top", in: app)
        for _ in 0..<4 {
            if scroll.frame.contains(send.frame) { break }
            scroll.swipeUp()
        }
        XCTAssertTrue(scroll.frame.contains(send.frame), "Manual scrolling must still reveal the entire footer")
        let last = app.buttons["question.option.3"]
        XCTAssertTrue(last.isHittable)
        XCTAssertGreaterThan(last.frame.height, shortHeight, "Long answers must retain natural text heights")
        tap(last)
        XCTAssertEqual(last.value as? String, "Selected")
        tap(send)
        assertSentMessage(in: app, contains: ["A: Full review"])
    }

    @MainActor
    private func assertStackedCards(_ first: XCUIElement, _ second: XCUIElement) {
        XCTAssertLessThan(first.frame.maxY, second.frame.minY, "Answers must stay vertically stacked")
        XCTAssertEqual(first.frame.minX, second.frame.minX, accuracy: 1)
        XCTAssertEqual(first.frame.width, second.frame.width, accuracy: 1)
        XCTAssertGreaterThanOrEqual(first.frame.height, 44 - 0.001)
        XCTAssertGreaterThanOrEqual(second.frame.height, 44 - 0.001)
    }

    @MainActor
    func testWorkspaceQuestionsStackAtDefaultPhoneSize() throws {
        let app = try openQuestions(scenario: "questions", collapsed: false)
        let first = app.buttons["question.option.0"]
        let second = app.buttons["question.option.1"]
        XCTAssertTrue(second.waitForExistence(timeout: Self.timeout))
        attachScreenshot("questions-default-phone", in: app)
        XCTAssertLessThan(first.frame.maxY, second.frame.minY, "Both answers must stack in the real phone host")
        XCTAssertEqual(first.frame.minX, second.frame.minX)
        XCTAssertTrue(first.isHittable)
        XCTAssertTrue(second.isHittable)
        tap(first)
        XCTAssertEqual(first.value as? String, "Selected")
        attachScreenshot("questions-selected-answer", in: app)
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
        tap(answerField(in: app))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Self.timeout))
        XCTAssertLessThan(first.frame.maxY, second.frame.minY, "The two-answer reference must also fit vertically above the keyboard")
        XCTAssertTrue(app.buttons["question.next"].isHittable)
        attachScreenshot("questions-vertical-keyboard", in: app)
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
        let editor = answerField(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Self.timeout), "The plus button must focus the native field")
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
        assertPendingBannerSideMargins(in: app, outerInset: 24)
        tap(composer)
        let draft = "Keep this draft\nfor later"
        composer.typeText(draft)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(keyboard.isHittable)
        attachScreenshot("questions-pending-keyboard", in: app)
        assertPendingBannerSideMargins(in: app, outerInset: 8)
        XCTAssertEqual(composer.value as? String, draft, "Return remains a newline, not a question-bypassing submit")
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.exists)
        XCTAssertFalse(send.isEnabled, "Pending questions require an explicit answer or dismissal")
        tap(app.buttons["question.answer"])
        let answer = answerField(in: app)
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
        attachScreenshot("questions-floating-keyboard", in: app)
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
}

extension QuestionWizardUITests {
    @MainActor
    private func attachScreenshot(_ name: String, in app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func assertPendingBannerSideMargins(in app: XCUIApplication, outerInset: CGFloat) {
        // Buttons sit 20pt inside the banner surface; use their native frames
        // without adding a test-only element or changing accessibility grouping.
        let dismiss = app.buttons["question.dismiss"].frame
        let answer = app.buttons["question.answer"].frame
        XCTAssertEqual(dismiss.minX - app.frame.minX, outerInset + 20, accuracy: 1)
        XCTAssertEqual(app.frame.maxX - answer.maxX, outerInset + 20, accuracy: 1)
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

    @MainActor private func answerField(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "question.freeText").firstMatch
    }

    @MainActor
    private func tapQuestionAction(_ identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: Self.timeout))
        let scroll = app.scrollViews.containing(.button, identifier: "question.option.0").firstMatch
        if scroll.exists {
            for _ in 0..<4 {
                if scroll.frame.contains(button.frame) { break }
                scroll.swipeUp()
            }
            XCTAssertTrue(scroll.frame.contains(button.frame), "The complete action must be reachable by vertical scrolling")
        }
        XCTAssertLessThanOrEqual(button.frame.maxY, answerField(in: app).frame.minY)
        XCTAssertTrue(button.isHittable)
        tap(button)
    }

    @MainActor
    private func tapOption(_ index: Int, in app: XCUIApplication) {
        let option = app.buttons["question.option.\(index)"]
        XCTAssertTrue(option.waitForExistence(timeout: Self.timeout))
        if !option.isHittable {
            app.scrollViews.containing(.button, identifier: "question.option.0").firstMatch.swipeUp()
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
