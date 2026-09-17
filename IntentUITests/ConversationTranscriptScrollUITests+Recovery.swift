import XCTest

// These end-to-end regressions retain staged narratives and observed timeout
// values so failures identify the exact viewport phase.
// swiftlint:disable function_body_length no_magic_numbers trailing_newline

extension ConversationTranscriptScrollUITests {
    /// Reproduces #338 by releasing the hooks row immediately after each
    /// cold entry reports settled.
    @MainActor
    func testHooksRowLandingRightAfterColdEntryKeepsLastMessageOnScreen() throws {
        for cycle in 1 ... Fixture.entryCycles {
            let context = "cold entry \(cycle)/\(Fixture.entryCycles) with the hooks row released on settle"
            try? FileManager.default.removeItem(at: hooksRowTriggerFile)
            let app = launchDemoApp(
                hooksRowTriggerFile: hooksRowTriggerFile,
                blockHydrationTriggerFile: blockHydrationTriggerFile
            )
            let opened = enterLongConversation(in: app, context: context)
            let lastMessage = opened.lastMessage
            let transcript = opened.transcript
            let endRow = EndRow.lastSuggestedPrompt(in: app)
            let hooksRow = app.staticTexts[Fixture.hooksRowLabel].firstMatch

            guard waitUntilSettled(
                on: lastMessage,
                named: "last assistant paragraph",
                in: opened,
                context: context,
                alsoReporting: (endRow.element, endRow.name)
            ) else {
                app.terminate()
                continue
            }
            XCTAssertFalse(
                hooksRow.exists,
                "\(context): the hooks row appeared before the trigger file was created"
            )
            let bottomBeforeRow = transcript.frame.maxY

            try Data().write(to: hooksRowTriggerFile)
            XCTAssertTrue(
                hooksRow.waitForExistence(timeout: Fixture.hooksRowTimeout),
                "\(context): hooks row never appeared after its trigger file was created"
            )
            XCTAssertTrue(
                waitUntil(timeout: 5) { transcript.frame.maxY < bottomBeforeRow },
                "\(context): transcript did not shrink after the hooks row appeared"
            )

            let repopulated = waitUntil(timeout: 5) { isInside(lastMessage, transcript) }
            let visibleBand = rows(intersecting: transcript)
            XCTAssertTrue(
                repopulated,
                "\(context): last paragraph is outside the transcript after the hooks row landed "
                    + "(\(visibleBand.count) visible rows) — "
                    + restingState(of: lastMessage, named: "last assistant paragraph", in: opened)
            )
            XCTAssertFalse(
                opened.goToEnd.exists,
                "\(context): Go to End appeared after the hooks row landed — "
                    + restingState(of: lastMessage, named: "last assistant paragraph", in: opened)
            )
            XCTAssertTrue(
                followReport(in: opened).hasPrefix(Fixture.landedFollowReportPrefix),
                "\(context): the entry follow no longer reports landed"
            )
            assertAtEnd(endRow, in: opened, context: "\(context), after the hooks row landed")
            assertStaysAtBottom(
                lastRow: lastMessage,
                named: "last assistant paragraph",
                endRow: endRow,
                in: opened,
                context: "\(context), after the hooks row landed"
            )
            app.terminate()
        }
    }

    /// Exercises the late slim-block hydration path from #338. This remains
    /// opt-in while #344 prevents reliably tapping the tool row in CI.
    @MainActor
    func testLateBlockHydrationNearEndAfterEntryKeepsLastMessageOnScreen() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["INTENT_UITEST_BLOCK_HYDRATION"] == "1",
            "the slim tool row cannot be tapped reliably from the resting end position: intent-hq/ios#344"
        )
        let app = launchDemoApp(
            hooksRowTriggerFile: hooksRowTriggerFile,
            blockHydrationTriggerFile: blockHydrationTriggerFile,
            standaloneSlimToolRows: true
        )
        let endRow = EndRow.lastSuggestedPrompt(in: app)
        for cycle in 1 ... Fixture.entryCycles {
            let entry = cycle == 1 ? "cold entry" : "warm re-entry"
            let context = "\(entry) \(cycle)/\(Fixture.entryCycles) with a late hydration near the end"
            try? FileManager.default.removeItem(at: blockHydrationTriggerFile)
            let opened = openLongConversation(in: app, context: context)
            let lastMessage = opened.lastMessage
            let transcript = opened.transcript
            let hydrationHint = app.descendants(matching: .any)
                .containing(NSPredicate(format: "label CONTAINS %@", Fixture.hydrationHintFragment))
                .firstMatch

            guard waitUntilSettled(
                on: lastMessage,
                named: "last assistant paragraph",
                in: opened,
                context: context,
                alsoReporting: (endRow.element, endRow.name)
            ) else {
                leaveConversation(in: app)
                continue
            }
            assertAtEnd(endRow, in: opened, context: context)
            XCTAssertFalse(hydrationHint.exists, "\(context): the slim tool row was already expanded")

            let toolRow = app.buttons
                .containing(NSPredicate(format: "label CONTAINS %@", Fixture.truncatedToolFileName))
                .firstMatch
            let navigationBarBottom = app.navigationBars.firstMatch.frame.maxY
            XCTAssertTrue(
                waitUntil(timeout: 5) {
                    isVisible(toolRow, in: transcript)
                        && (frame(of: toolRow)?.minY ?? -.infinity) >= navigationBarBottom
                },
                "\(context): slim tool row is not tappable — "
                    + restingState(of: toolRow, named: "slim tool row", in: opened)
            )
            toolRow.tap()
            XCTAssertTrue(
                hydrationHint.waitForExistence(timeout: 5),
                "\(context): the hydration hint did not appear"
            )
            guard waitUntilSettled(
                on: lastMessage,
                named: "last assistant paragraph",
                in: opened,
                context: "\(context), after expanding the slim tool row",
                alsoReporting: (endRow.element, endRow.name)
            ) else {
                leaveConversation(in: app)
                continue
            }
            XCTAssertTrue(hydrationHint.exists, "\(context): hydration gate did not hold the request")

            try Data().write(to: blockHydrationTriggerFile)
            XCTAssertTrue(
                waitUntil(timeout: Fixture.blockHydrationTimeout) { !hydrationHint.exists },
                "\(context): full block did not hydrate after the trigger file was created"
            )

            let hydrated = "\(context), after hydration re-measured the row"
            let repopulated = waitUntil(timeout: 5) { isInside(lastMessage, transcript) }
            let visibleBand = rows(intersecting: transcript)
            XCTAssertTrue(
                repopulated,
                "\(hydrated): last paragraph is outside the transcript "
                    + "(\(visibleBand.count) visible rows) — "
                    + restingState(of: lastMessage, named: "last assistant paragraph", in: opened)
            )
            XCTAssertFalse(
                opened.goToEnd.exists,
                "\(hydrated): Go to End appeared — "
                    + restingState(of: lastMessage, named: "last assistant paragraph", in: opened)
            )
            assertAtEnd(endRow, in: opened, context: hydrated)
            XCTAssertTrue(
                followReport(in: opened).hasPrefix(Fixture.landedFollowReportPrefix),
                "\(hydrated): the follow no longer reports landed"
            )
            assertStaysAtBottom(
                lastRow: lastMessage,
                named: "last assistant paragraph",
                endRow: endRow,
                in: opened,
                context: hydrated
            )
            leaveConversation(in: app)
        }
    }
}
// swiftlint:enable function_body_length no_magic_numbers trailing_newline