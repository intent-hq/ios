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
    /// transcript). The test first checks the transcript actually shrank,
    /// so a run without a software keyboard cannot pass without exercising
    /// the inset. A simulator with a hardware keyboard attached (Simulator
    /// > I/O > Keyboard > Connect Hardware Keyboard) raises no software
    /// keyboard at all: that is the test's prerequisite, not its subject,
    /// so it skips there — naming the setting — instead of failing the
    /// suite (intent-hq/ios#385). A software keyboard that is up while the
    /// transcript kept its height is still a failure. It settles on the end
    /// row itself: while the keyboard is up the transcript is shorter than
    /// the last assistant paragraph plus the rows after it, so the paragraph
    /// is clipped at the top while the transcript is at the end.
    ///
    /// Only the keyboard-open half is exercised. Dismissing the keyboard
    /// from a UI test needs a tap inside the transcript, and every viable
    /// tap site fires app behaviour: level with the suggested prompts the
    /// tap also sends the first prompt, and on a message body the Textual
    /// text-interaction view becomes first responder and keeps the
    /// keyboard up.
    @MainActor
    func testKeyboardOpenKeepsTranscriptAtEnd() throws {
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
        let shrank = waitUntil(timeout: Fixture.keyboardTimeout) {
            bottomWithKeyboard = transcript.frame.maxY
            return bottomWithKeyboard <= bottomBeforeKeyboard - Fixture.keyboardMinimumShrink
        }
        if !shrank {
            let geometry = "(bottom edge \(bottomWithKeyboard) vs \(bottomBeforeKeyboard) before)"
            try XCTSkipUnless(
                app.keyboards.firstMatch.exists,
                "prerequisite not met: no software keyboard appeared within \(Int(Fixture.keyboardTimeout)) s of "
                    + "focusing the composer and the transcript did not shrink \(geometry). A hardware keyboard may be "
                    + "attached to the simulator: check Simulator > I/O > Keyboard > Connect Hardware Keyboard is off "
                    + "(`defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false` while "
                    + "Simulator.app is not running; see scripts/xcodebuild.sh) and re-run"
            )
            XCTFail(
                "the software keyboard is up but the transcript did not shrink by "
                    + "\(Int(Fixture.keyboardMinimumShrink)) pt within \(Int(Fixture.keyboardTimeout)) s \(geometry) — "
                    + "keyboard avoidance did not resize the transcript"
            )
            return
        }
        assertRestsAtBottom(
            lastRow: endRow.element,
            named: endRow.name,
            endRow: endRow,
            in: opened,
            context: "after the keyboard opened"
        )
    }
}
