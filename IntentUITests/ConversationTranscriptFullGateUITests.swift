import XCTest

extension ConversationTranscriptScrollUITests {
    // swiftlint:disable no_magic_numbers
    @MainActor
    // swiftlint:disable:next function_body_length
    func testGoToEndAppearsWhenScrolledUpAndHidesAtBottom() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["INTENT_UITEST_FULL_GATE_REPRO"] == "1",
            "Temporary quarantine for an unclassified full-gate failure; related investigation (cause unproven): "
                + "https://github.com/intent-hq/ios/issues/427; opt in with TEST_RUNNER_INTENT_UITEST_FULL_GATE_REPRO=1."
        )
        let app = launchDemoApp(hooksRowTriggerFile: hooksRowTriggerFile)
        let opened = openLongConversation(in: app)
        let lastMessage = opened.lastMessage
        let goToEnd = opened.goToEnd
        let transcript = opened.transcript
        let endRow = EndRow.lastSuggestedPrompt(in: app)

        assertRestsAtBottom(
            lastRow: lastMessage,
            named: "last assistant paragraph",
            endRow: endRow,
            in: opened,
            context: "after opening"
        )

        swipeDown(transcript, times: 3)
        XCTAssertTrue(
            goToEnd.appears(timeout: 5),
            "Go to End did not appear after scrolling the transcript up"
        )

        goToEnd.tap()
        guard waitUntilSettled(
            on: lastMessage,
            named: "last assistant paragraph",
            in: opened,
            context: "after Go to End",
            alsoReporting: (endRow.element, endRow.name)
        ) else { return }
        assertAtEnd(endRow, in: opened, context: "after Go to End")
        XCTAssertTrue(
            goToEnd.disappears(timeout: 5),
            "Go to End stayed visible after tapping it — "
                + restingState(of: lastMessage, named: "last assistant paragraph", in: opened)
        )

        swipeDown(transcript, times: 3)
        XCTAssertTrue(
            goToEnd.appears(timeout: 5),
            "Go to End did not reappear after scrolling up a second time"
        )
        var swipesLeft = 12
        while swipesLeft > 0, !goToEnd.disappears(timeout: 1) {
            transcript.swipeUp()
            swipesLeft -= 1
        }
        XCTAssertTrue(
            goToEnd.disappears(timeout: 5),
            "Go to End stayed visible after scrolling back to the bottom"
        )
        XCTAssertTrue(
            waitUntilVisible(lastMessage, in: transcript, timeout: 5),
            "last transcript message is not visible after scrolling back to the bottom"
        )
    }
    // swiftlint:enable no_magic_numbers

    // swiftlint:disable no_magic_numbers
    @MainActor
    func testFooterRowAppearanceKeepsTranscriptAtBottomAndGoToEndHidden() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["INTENT_UITEST_FULL_GATE_REPRO"] == "1",
            "Temporary quarantine for an unclassified full-gate failure; related investigation (cause unproven): "
                + "https://github.com/intent-hq/ios/issues/427; opt in with TEST_RUNNER_INTENT_UITEST_FULL_GATE_REPRO=1."
        )
        let app = launchDemoApp(hooksRowTriggerFile: hooksRowTriggerFile)
        let opened = openLongConversation(in: app)
        let lastMessage = opened.lastMessage
        let goToEnd = opened.goToEnd
        let transcript = opened.transcript
        let endRow = EndRow.lastSuggestedPrompt(in: app)

        guard let baseline = footerBaseline(in: app, opened: opened, endRow: endRow) else { return }
        let hooksRow = baseline.hooksRow
        let bottomBeforeRow = baseline.transcriptBottom
        let gapBeforeRow = baseline.messageGap
        let gapToBottom = { transcript.frame.maxY - (frame(of: lastMessage)?.maxY ?? .nan) }

        try Data().write(to: hooksRowTriggerFile)
        XCTAssertTrue(
            hooksRow.appears(timeout: Fixture.hooksRowTimeout),
            "hooks row never appeared under the transcript after the trigger file was created"
        )
        let hookChip = app.descendants(matching: .any)
            .containing(NSPredicate(format: "label CONTAINS %@", Fixture.hookName))
            .firstMatch
        XCTAssertTrue(
            hookChip.appears(timeout: 5),
            "hook chip never appeared in the hooks row"
        )
        XCTAssertTrue(
            waitUntil(timeout: 5) { transcript.frame.maxY < bottomBeforeRow },
            "transcript did not shrink when the hooks row appeared (\(transcript.frame.maxY) vs \(bottomBeforeRow))"
        )

        var gapAfterRow = gapToBottom()
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                gapAfterRow = gapToBottom()
                return abs(gapAfterRow - gapBeforeRow) <= Fixture.rePinTolerance
            },
            "transcript did not re-pin to the bottom after the hooks row appeared: "
                + "last message sat \(gapAfterRow) pt above the bottom edge, \(gapBeforeRow) pt before the row — "
                + restingState(of: lastMessage, named: "last assistant paragraph", in: opened)
        )
        assertStaysAtBottom(
            lastRow: lastMessage,
            named: "last assistant paragraph",
            endRow: endRow,
            in: opened,
            context: "after the hooks row shrank the transcript"
        )
    }
    // swiftlint:enable no_magic_numbers

    @MainActor
    // swiftlint:disable:next function_body_length
    func testFirstOpenOfLongConversationShowsLastMessageWithNoBlankBand() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["INTENT_UITEST_FULL_GATE_REPRO"] == "1",
            "Temporary quarantine for an unclassified full-gate failure; related investigation (cause unproven): "
                + "https://github.com/intent-hq/ios/issues/427; opt in with TEST_RUNNER_INTENT_UITEST_FULL_GATE_REPRO=1."
        )
        for cycle in 1 ... Fixture.entryCycles {
            let context = "cold entry \(cycle)/\(Fixture.entryCycles)"
            let app = launchDemoApp(hooksRowTriggerFile: hooksRowTriggerFile)
            let endRow = EndRow.lastSuggestedPrompt(in: app)
            let opened = enterLongConversation(
                in: app,
                context: context,
                evidence: recoveryEvidence(cycle: cycle, endRow: endRow)
            )
            let lastMessage = opened.lastMessage
            let transcript = opened.transcript

            let settled = waitUntilSettled(
                on: lastMessage,
                named: "last assistant paragraph",
                in: opened,
                context: context,
                alsoReporting: (endRow.element, endRow.name)
            )
            let visibleBand = rows(intersecting: transcript)
            attachRecoveryEvidence()
            XCTAssertFalse(
                visibleBand.isEmpty,
                "\(context): the transcript's visible band is empty — no message row intersects the transcript frame — "
                    + restingState(of: lastMessage, named: "last assistant paragraph", in: opened)
            )
            guard settled else {
                app.terminate()
                continue
            }
            assertAtEnd(
                endRow,
                in: opened,
                context: "\(context) (\(visibleBand.count) row(s) in the visible band)"
            )

            assertStaysAtBottom(
                lastRow: lastMessage,
                named: "last assistant paragraph",
                endRow: endRow,
                in: opened,
                context: context
            )
            XCTAssertFalse(
                app.staticTexts[Fixture.hooksRowLabel].exists,
                "\(context): the hooks row landed during the cold entry; the fixture trigger file did not hold it back"
            )
            app.terminate()
        }
    }
}
