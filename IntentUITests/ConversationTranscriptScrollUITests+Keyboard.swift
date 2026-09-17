import XCTest

extension ConversationTranscriptScrollUITests {
    /// Focusing the composer raises the software keyboard, and SwiftUI's
    /// keyboard avoidance shrinks the transcript from below over the
    /// keyboard animation while the lazy stack re-estimates the rows it
    /// realizes and drops. A transcript resting at the end must still be
    /// there once the resize has settled: the end row rests
    /// `Fixture.endRowGap` above the transcript's (moved) bottom edge with
    /// no Go to End, and holds over the quiet window (intent-hq/ios#276:
    /// the viewport intermittently landed at the very top of the long
    /// transcript). The test first asserts the transcript actually shrank,
    /// so a simulator with a hardware keyboard attached fails there instead
    /// of passing without exercising the inset. It settles on the end row
    /// itself: while the keyboard is up the transcript is shorter than the
    /// last assistant paragraph plus the rows after it, so the paragraph
    /// is clipped at the top while the transcript is at the end.
    ///
    /// Only the keyboard-open half is exercised. Dismissing the keyboard
    /// from a UI test needs a tap inside the transcript, and every viable
    /// tap site fires app behaviour: level with the suggested prompts the
    /// tap also sends the first prompt, and on a message body the Textual
    /// text-interaction view becomes first responder and keeps the
    /// keyboard up.
    @MainActor
    func testKeyboardOpenKeepsTranscriptAtEnd() {
        let app = launchDemoApp(hooksRowTriggerFile: hooksRowTriggerFile)
        let opened = openLongConversation(in: app)
        let transcript = opened.transcript
        let endRow = EndRow.lastSuggestedPrompt(in: app)
        let composer = app.textViews[Fixture.composerIdentifier].firstMatch
        assertRestsAtBottom(
            lastRow: opened.lastMessage,
            named: "last assistant paragraph",
            endRow: endRow,
            in: opened,
            context: "before focusing the composer"
        )
        XCTAssertTrue(
            composer.waitForExistence(timeout: Fixture.elementTimeout),
            "composer text view not found"
        )
        let bottomBeforeKeyboard = transcript.frame.maxY

        composer.tap()
        var bottomWithKeyboard = transcript.frame.maxY
        XCTAssertTrue(
            waitUntil(timeout: Fixture.keyboardTimeout) {
                bottomWithKeyboard = transcript.frame.maxY
                return bottomWithKeyboard <= bottomBeforeKeyboard - Fixture.keyboardMinimumShrink
            },
            "the transcript did not shrink after the composer was focused "
                + "(bottom edge \(bottomWithKeyboard) vs \(bottomBeforeKeyboard) before) — the software keyboard "
                + "did not raise; is a hardware keyboard attached to the simulator?"
        )
        assertRestsAtBottom(
            lastRow: endRow.element,
            named: endRow.name,
            endRow: endRow,
            in: opened,
            context: "after the keyboard opened"
        )
    }
}
