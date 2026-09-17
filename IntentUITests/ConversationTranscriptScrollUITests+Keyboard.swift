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
    /// fails here instead of passing without exercising the inset. While
    /// the keyboard is up the transcript is shorter than the last
    /// assistant paragraph plus the rows after it, so that half-cycle
    /// settles on the end row itself; once the keyboard is down the
    /// paragraph fits again and is the settle target, as elsewhere.
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

            // 2. Dismiss it with a tap on the transcript's own padding (the
            //    scroll view's keyboard-dismiss recognizer; the padding
            //    holds no link): the transcript grows back.
            transcript.coordinate(withNormalizedOffset: Fixture.keyboardDismissTapOffset).tap()
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
            assertRestsAtBottom(
                lastRow: lastMessage,
                named: "last assistant paragraph",
                endRow: endRow,
                in: opened,
                context: "cycle \(cycle): after the keyboard dismissed"
            )
        }
    }
}
