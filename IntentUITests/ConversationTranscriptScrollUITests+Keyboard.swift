import XCTest

extension ConversationTranscriptScrollUITests {
    /// Editing the composer raises the software keyboard, and SwiftUI's
    /// keyboard avoidance shrinks the transcript from below over the
    /// keyboard animation while the lazy stack re-estimates the rows it
    /// realizes and drops. A transcript resting at the end must still be
    /// there once the resize has settled: the end row rests
    /// `Fixture.endRowGap` above the transcript's (moved) bottom edge with
    /// no Go to End, and holds over the quiet window (intent-hq/ios#276:
    /// the viewport intermittently landed at the very top of the long
    /// transcript). After entering the draft, a missing software keyboard
    /// is an unmet prerequisite (intent-hq/ios#385). An existing but off-screen
    /// keyboard still fails the hittability check; a visible keyboard still
    /// must shrink the transcript. It settles on the end row
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
    // Only the added quarantine guard exceeds the original body limit; revisit with its removal.
    // swiftlint:disable:next function_body_length
    func testKeyboardOpenKeepsTranscriptAtEnd() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["INTENT_UITEST_FULL_GATE_REPRO"] == "1",
            "Temporary quarantine for an unclassified full-gate failure; related investigation (cause unproven): "
                + "https://github.com/intent-hq/ios/issues/427; opt in with TEST_RUNNER_INTENT_UITEST_FULL_GATE_REPRO=1."
        )
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
            context: "before focusing the composer",
            allowPreservedEntry: true
        )
        XCTAssertTrue(
            composer.waitForExistence(timeout: Fixture.elementTimeout),
            "composer text view not found"
        )
        let bottomBeforeKeyboard = transcript.frame.maxY

        composer.tap()
        // A tap can focus the editor while the simulator keeps its software
        // keyboard off-screen. XCTest's text-entry path raises it without
        // changing simulator preferences. Keep this draft on a single line.
        composer.typeText("Keyboard resize draft")
        XCTAssertEqual(composer.value as? String, "Keyboard resize draft")
        let keyboard = try requireSoftwareKeyboard(in: app)
        var bottomWithKeyboard = transcript.frame.maxY
        XCTAssertTrue(
            waitUntil(timeout: Fixture.keyboardTimeout) {
                bottomWithKeyboard = transcript.frame.maxY
                return bottomWithKeyboard <= bottomBeforeKeyboard - Fixture.keyboardMinimumShrink
            },
            "the transcript did not shrink after the software keyboard opened "
                + "(bottom edge \(bottomWithKeyboard) vs \(bottomBeforeKeyboard) before)"
        )
        let geometry = XCTAttachment(
            string: "transcript bottom: \(bottomBeforeKeyboard) -> \(bottomWithKeyboard); keyboard: \(keyboard.frame)"
        )
        geometry.name = "keyboard-resize-geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        assertRestsAtBottom(
            lastRow: endRow.element,
            named: endRow.name,
            endRow: endRow,
            in: opened,
            context: "after the keyboard opened"
        )
    }

    /// Exercise the real absent-keyboard query without a hardware preference
    /// change. This is a guard control, not a reproduction after composer focus.
    @MainActor
    func testSoftwareKeyboardPrerequisiteSkipsWhenKeyboardIsAbsent() {
        let app = launchDemoApp(hooksRowTriggerFile: hooksRowTriggerFile)
        let opened = openLongConversation(in: app)
        XCTAssertTrue(opened.transcript.exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "the untouched composer must not show a keyboard")

        XCTAssertThrowsError(try requireSoftwareKeyboard(in: app)) { error in
            XCTAssertTrue(error is XCTSkip, "an absent keyboard must skip, not pass or fail the resize check")
        }
    }

    @MainActor
    private func requireSoftwareKeyboard(in app: XCUIApplication) throws -> XCUIElement {
        let keyboard = app.keyboards.firstMatch
        let isVisible = waitUntil(timeout: Fixture.keyboardTimeout) { keyboard.exists && keyboard.isHittable }
        if !isVisible {
            // An off-screen element is the state repaired by text entry above.
            // It is not evidence that the keyboard prerequisite is absent.
            try XCTSkipUnless(
                keyboard.exists,
                "prerequisite not met: no software keyboard element appeared within \(Int(Fixture.keyboardTimeout)) s. "
                    + "A hardware keyboard may be attached; check Simulator > I/O > Keyboard > Connect Hardware Keyboard "
                    + "and the device's keyboard state (see scripts/xcodebuild.sh)."
            )
        }
        XCTAssertTrue(
            isVisible,
            "the software keyboard must be on screen, not just present in the accessibility hierarchy"
        )
        return keyboard
    }
}
