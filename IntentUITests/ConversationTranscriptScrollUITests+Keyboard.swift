import XCTest

extension ConversationTranscriptScrollUITests {
    /// Focusing the composer raises the software keyboard, and SwiftUI's
    /// keyboard avoidance shrinks the transcript from below over the
    /// keyboard animation while the lazy stack re-estimates the rows it
    /// realizes and drops; dismissing it grows the transcript back. A
    /// transcript resting at the end must stay there through both: once
    /// the resize has settled, the end row rests `Fixture.endRowGap` above
    /// the transcript's (moved) bottom edge with no Go to End, and holds
    /// over the quiet window (intent-hq/ios#276: the viewport intermittently
    /// landed at the very top of the long transcript, on the open in one
    /// run and on the dismiss in another, from the second cycle on — so
    /// the cycle is repeated). Each cycle first asserts the transcript
    /// actually resized, so a simulator with a hardware keyboard attached
    /// fails here instead of passing without exercising the inset. Both
    /// half-cycles settle on the end row itself: while the keyboard is up
    /// the transcript is shorter than the last assistant paragraph plus
    /// the rows after it, and once the keyboard is down the paragraph
    /// comes to rest inside the grown transcript a beat before the rows
    /// under it are realized again — settling on the paragraph there
    /// asserted on a transcript still re-laying out its end. With the
    /// keyboard down the paragraph fits, so it must also be on screen.
    @MainActor
    func testKeyboardOpenAndDismissKeepTranscriptAtEnd() {
        let app = launchDemoApp(hooksRowTriggerFile: hooksRowTriggerFile)
        let opened = openLongConversation(in: app)
        let lastMessage = opened.lastMessage
        let transcript = opened.transcript
        let endRow = EndRow.lastSuggestedPrompt(in: app)
        let composer = app.textViews[Fixture.composerIdentifier].firstMatch
        assertRestsAtBottom(
            lastRow: lastMessage,
            named: "last assistant paragraph",
            endRow: endRow,
            in: opened,
            context: "before focusing the composer"
        )
        XCTAssertTrue(
            composer.waitForExistence(timeout: Fixture.elementTimeout),
            "composer text view not found"
        )

        for cycle in 1 ... Fixture.keyboardCycles {
            let bottomBeforeKeyboard = transcript.frame.maxY

            // 1. Focus the composer: the keyboard raises and the transcript
            //    shrinks from below.
            composer.tap()
            var bottomWithKeyboard = transcript.frame.maxY
            XCTAssertTrue(
                waitUntil(timeout: Fixture.keyboardTimeout) {
                    bottomWithKeyboard = transcript.frame.maxY
                    return bottomWithKeyboard <= bottomBeforeKeyboard - Fixture.keyboardMinimumShrink
                },
                "cycle \(cycle): the transcript did not shrink after the composer was focused "
                    + "(bottom edge \(bottomWithKeyboard) vs \(bottomBeforeKeyboard) before) — the software keyboard "
                    + "did not raise; is a hardware keyboard attached to the simulator?"
            )
            assertRestsAtBottom(
                lastRow: endRow.element,
                named: endRow.name,
                endRow: endRow,
                in: opened,
                context: "cycle \(cycle): after the keyboard opened"
            )

            // 2. Dismiss it with a tap on the last assistant paragraph (the
            //    scroll view's keyboard-dismiss recognizer sees it; the
            //    paragraph holds no link or button): the transcript grows
            //    back.
            lastMessage.coordinate(withNormalizedOffset: Fixture.keyboardDismissTapOffset).tap()
            var bottomAfterDismiss = transcript.frame.maxY
            XCTAssertTrue(
                waitUntil(timeout: Fixture.keyboardTimeout) {
                    bottomAfterDismiss = transcript.frame.maxY
                    return abs(bottomAfterDismiss - bottomBeforeKeyboard) <= Fixture.rePinTolerance
                },
                "cycle \(cycle): the transcript did not grow back after tapping it "
                    + "(bottom edge \(bottomAfterDismiss) vs \(bottomBeforeKeyboard) before the keyboard) — "
                    + "the keyboard did not dismiss"
            )
            let dismissed = "cycle \(cycle): after the keyboard dismissed"
            let sentAPrompt = app.staticTexts[Fixture.thinkingIndicatorLabel].firstMatch.exists
                || message(in: app, containing: Fixture.firstSuggestedPrompt).exists
            XCTAssertFalse(
                sentAPrompt,
                "\(dismissed): the dismiss tap also sent a suggested prompt — "
                    + endOfTranscriptDiagnostics(in: app, opened: opened)
            )
            guard !sentAPrompt, waitUntilSettled(
                on: endRow.element,
                named: endRow.name,
                in: opened,
                context: dismissed,
                alsoReporting: (lastMessage, "last assistant paragraph"),
                diagnostics: { self.endOfTranscriptDiagnostics(in: app, opened: opened) }
            ) else { return }
            assertAtEnd(endRow, in: opened, context: dismissed)
            assertStaysAtBottom(lastRow: endRow.element, named: endRow.name, endRow: endRow, in: opened, context: dismissed)
            XCTAssertTrue(
                isInside(lastMessage, transcript),
                "cycle \(cycle): after the keyboard dismissed, the last assistant paragraph is not on screen "
                    + "although it fits under the end row — "
                    + restingState(of: lastMessage, named: "last assistant paragraph", in: opened)
            )
        }
    }

    /// What the transcript's end looks like when the end row is missing:
    /// each suggested prompt's frame (or absence), whether a send is in
    /// flight (the thinking indicator, or a user row echoing the first
    /// prompt — a dismiss tap that also hit a prompt hides the prompts),
    /// and the text rows intersecting the transcript, top to bottom.
    @MainActor
    private func endOfTranscriptDiagnostics(in app: XCUIApplication, opened: OpenConversation) -> String {
        let transcript = opened.transcript
        let prompts = (0 ..< 3).map { index -> String in
            let prompt = app.buttons["transcript.suggestedPrompt.\(index)"].firstMatch
            return "prompt \(index) " + (frame(of: prompt).map { "\($0)" } ?? "absent")
        }
        let inFlight = "thinking indicator "
            + (app.staticTexts[Fixture.thinkingIndicatorLabel].firstMatch.exists ? "PRESENT" : "absent")
            + ", user row echoing prompt 0 "
            + (message(in: app, containing: Fixture.firstSuggestedPrompt).exists ? "PRESENT" : "absent")
        let visible = rows(intersecting: transcript).compactMap { row -> String? in
            guard let rowFrame = frame(of: row) else { return nil }
            let label = row.label.replacingOccurrences(of: "\n", with: " ")
            return "[\(Int(rowFrame.minY))…\(Int(rowFrame.maxY))] \(label.prefix(40))"
        }
        return "diagnostics: " + prompts.joined(separator: ", ") + "; " + inFlight
            + "; \(transcript.staticTexts.count) text rows in hierarchy, on screen: "
            + visible.joined(separator: " | ")
    }
}
