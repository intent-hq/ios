import XCTest

/// Guards the "Go to End" affordance of the conversation transcript against
/// `--demo-data` fixtures: hidden while resting at the bottom, shown once the
/// user scrolls up, hidden again after tapping it or scrolling back down,
/// still hidden — with the last message still on screen — when a footer row
/// (the background-hooks chip row) appears under the settled transcript,
/// still hidden after tapping a suggested prompt under the last message,
/// hidden on every one of several consecutive entries into the conversation,
/// hidden — with the last message on screen, no blank band, and the prompt
/// rows under it on screen — once a cold entry has settled
/// (intent-hq/ios#304), hidden when the hooks row lands after a cold entry or
/// a slim-truncated tool row hydrates after entry (intent-hq/ios#338),
/// hidden after a single tap from the very top of the transcript (#305),
/// and — the controlled cases in `+Recovery` — absent once the real recovery
/// recovered an end row the fixture withdrew on the test's signal, present
/// once it gave up over one kept withdrawn. Those launches and the cold-entry
/// ones attach a JSON evidence record (`recoveryEvidence`).
/// Every wait is settlement polling on the app's own state, never a guessed
/// idle delay: a forced follow (entry, Go to End, a send) reports its
/// outcome in the transcript's accessibility value once its live geometry
/// has come to rest, and the last row is asserted inside the transcript
/// only once that report is in and the row's frame has held still
/// (`waitUntilSettled`). Sampling the geometry alone raced the follow: two
/// samples 0.25 s apart also agree while the follow waits out its debounce
/// or between two of its landing corrections, and the correction that then
/// ran moved the rows under the assertions (intent-hq/ios#313,
/// intent-hq/ios#307, intent-hq/intent#5109). The report is
/// synchronization only — its outcome is not asserted, as CI simulators
/// exhaust the landing budget (`giveUp`) with the viewport at the end — so
/// the end itself is asserted on geometry: the transcript's final content
/// row (`EndRow`) rests `Fixture.endRowGap` above the bottom edge
/// (`assertAtEnd`), which a viewport stalled past the end over a blank band
/// or short of the end fails where containment alone would not. Frames are
/// read from single snapshots (`frame(of:)`): `exists` followed by `frame`
/// resolves the query twice and a row the lazy stack derealizes in between
/// fails the test outright.
/// Every "rests at the bottom" failure message reports the follow's report,
/// whether Go to End is present and where the last row's frame lies
/// relative to the transcript's frame (ABOVE it: viewport past the end over
/// a blank band; BELOW it: viewport short of the end) so a CI failure is
/// diagnostic on its own (intent-hq/ios#281).
/// Runs under the `Intent` scheme (`scripts/xcodebuild.sh test-ios`, CI).
/// The transcript is the coordinator-shaped, 150+-message
/// `DemoFixtures.longConversationMessages` (tool-call groups, agent-to-agent
/// rows, code fences, tables) served for the "Deflake payment integration
/// tests" workspace, whose single foreground agent opens straight into the
/// transcript from the workspace row with the "Waiting for all" footer
/// already under it. That workspace's `hook.list` fixture waits on
/// `DemoFixtures.longConversationHookListGate` — a delay by default, or a
/// trigger file — and every test here launches with the trigger file, so
/// the hooks row never lands on its own clock: only the footer test
/// releases it, once the transcript has been observed settled. On its
/// default clock the row lands ~4 s after entry, inside every test's
/// settle and quiet windows, and a row landing right after an entry had
/// settled left the transcript blank with Go to End hidden on CI
/// (intent-hq/ios#338) — a second event, a container resize, with its own
/// outcome, in tests that measure the entry, a tap or a send.
nonisolated final class ConversationTranscriptScrollUITests: XCTestCase {
    // Trigger URLs are shared with recovery tests extracted into a companion file.
    // swiftlint:disable test_case_accessibility
    /// The file the fixture's hooks-row gate waits on (see
    /// `Fixture.hooksRowTriggerFileArgumentPrefix`): one path per test
    /// (XCTest instantiates the case per test method), never created unless
    /// the test releases the row.
    let hooksRowTriggerFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcript-hooks-row-\(UUID().uuidString).trigger")

    let blockHydrationTriggerFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcript-block-hydration-\(UUID().uuidString).trigger")

    /// The file the fixture's end-derealization gate waits on (see
    /// `Fixture.endDerealizationTriggerArgumentPrefix`), passed only by
    /// the two controlled-recovery tests.
    let endDerealizationTriggerFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcript-end-derealization-\(UUID().uuidString).trigger")

    /// The launch whose evidence record is still owed (see `recoveryEvidence`):
    /// flushed by `attachRecoveryEvidence`, or in teardown after a failure.
    var pendingRecoveryEvidence: PendingRecoveryEvidence?
    // swiftlint:enable test_case_accessibility

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        try? FileManager.default.removeItem(at: hooksRowTriggerFile)
        try? FileManager.default.removeItem(at: blockHydrationTriggerFile)
        try? FileManager.default.removeItem(at: endDerealizationTriggerFile)
    }

    override func tearDownWithError() throws {
        // XCTest runs teardown on the main thread, so the main-actor hop is
        // sound; nonisolated(unsafe) keeps the test case out of the region check.
        nonisolated(unsafe) let test = self
        MainActor.assumeIsolated { test.attachPendingRecoveryEvidence() }
        try? FileManager.default.removeItem(at: hooksRowTriggerFile)
        try? FileManager.default.removeItem(at: blockHydrationTriggerFile)
        try? FileManager.default.removeItem(at: endDerealizationTriggerFile)
        try super.tearDownWithError()
    }

    @MainActor
    func testGoToEndAppearsWhenScrolledUpAndHidesAtBottom() {
        let app = launchDemoApp(hooksRowTriggerFile: hooksRowTriggerFile)
        let opened = openLongConversation(in: app)
        let lastMessage = opened.lastMessage
        let goToEnd = opened.goToEnd
        let transcript = opened.transcript
        let endRow = EndRow.lastSuggestedPrompt(in: app)

        // 1. At rest at the bottom the button must stay hidden: the entry
        //    follow reports and the last message rests inside the transcript
        //    with the end row at the end, then the button must not appear
        //    over the quiet window — waitForNonExistence would pass
        //    immediately before the transcript had measured anything.
        assertRestsAtBottom(
            lastRow: lastMessage,
            named: "last assistant paragraph",
            endRow: endRow,
            in: opened,
            context: "after opening"
        )

        // 2. Scrolling up (content moves down) reveals it.
        swipeDown(transcript, times: 3)
        XCTAssertTrue(
            goToEnd.waitForExistence(timeout: 5),
            "Go to End did not appear after scrolling the transcript up"
        )

        // 3. Tapping it returns to the bottom and hides it: the tap's forced
        //    follow reports with the last message inside the transcript and
        //    the end row at the end.
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
            goToEnd.waitForNonExistence(timeout: 5),
            "Go to End stayed visible after tapping it — "
                + restingState(of: lastMessage, named: "last assistant paragraph", in: opened)
        )

        // 4. Scroll up again, then scroll back down by hand: the button must
        //    reappear and then hide without the tap path.
        swipeDown(transcript, times: 3)
        XCTAssertTrue(
            goToEnd.waitForExistence(timeout: 5),
            "Go to End did not reappear after scrolling up a second time"
        )
        //    The last message is several lines tall, so its centre can be
        //    on screen while the viewport is still beyond atBottomThreshold;
        //    keep swiping (bounded) until the button reports the bottom.
        var swipesLeft = 12
        while swipesLeft > 0, !goToEnd.waitForNonExistence(timeout: 1) {
            transcript.swipeUp()
            swipesLeft -= 1
        }
        XCTAssertTrue(
            goToEnd.waitForNonExistence(timeout: 5),
            "Go to End stayed visible after scrolling back to the bottom"
        )
        XCTAssertTrue(
            waitUntilVisible(lastMessage, in: transcript, timeout: 5),
            "last transcript message is not visible after scrolling back to the bottom"
        )
    }

    /// A footer row appearing under a transcript resting at the bottom shrinks
    /// the scroll container; the transcript must re-pin so the last message
    /// keeps its distance from the transcript's bottom edge and Go to End
    /// stays hidden (#272). The distance is what discriminates: the row is
    /// shorter than the at-bottom threshold, so an unpinned transcript shows
    /// no Go to End either and its last message, ~36 pt lower relative to
    /// the shrunk transcript, still passes a midpoint visibility check.
    @MainActor
    func testFooterRowAppearanceKeepsTranscriptAtBottomAndGoToEndHidden() throws {
        let app = launchDemoApp(hooksRowTriggerFile: hooksRowTriggerFile)
        let opened = openLongConversation(in: app)
        let lastMessage = opened.lastMessage
        let goToEnd = opened.goToEnd
        let transcript = opened.transcript
        let endRow = EndRow.lastSuggestedPrompt(in: app)

        // 1. Settle at the bottom while the hooks row is held back by the
        //    trigger file: the entry follow has reported and the last message
        //    rests inside the transcript with the end row at the end, so the
        //    baseline gap is not a sample taken during a still-animating
        //    follow or its landing retry, nor one of a viewport past the end.
        guard let baseline = footerBaseline(in: app, opened: opened, endRow: endRow) else { return }
        let hooksRow = baseline.hooksRow
        let bottomBeforeRow = baseline.transcriptBottom
        let gapBeforeRow = baseline.messageGap
        let gapToBottom = { transcript.frame.maxY - (frame(of: lastMessage)?.maxY ?? .nan) }

        // 2. Release the hooks row; it appears and shrinks the transcript from below.
        try Data().write(to: hooksRowTriggerFile)
        XCTAssertTrue(
            hooksRow.waitForExistence(timeout: Fixture.hooksRowTimeout),
            "hooks row never appeared under the transcript after the trigger file was created"
        )
        let hookChip = app.descendants(matching: .any)
            .containing(NSPredicate(format: "label CONTAINS %@", Fixture.hookName))
            .firstMatch
        XCTAssertTrue(
            hookChip.waitForExistence(timeout: 5),
            "hook chip never appeared in the hooks row"
        )
        XCTAssertTrue(
            waitUntil(timeout: 5) { transcript.frame.maxY < bottomBeforeRow },
            "transcript did not shrink when the hooks row appeared (\(transcript.frame.maxY) vs \(bottomBeforeRow))"
        )

        // 3. Re-pinned: the last message sits at the same distance from the
        //    (new) bottom edge as before the row, then no Go to End, the
        //    last message inside the transcript and the end row at the end
        //    over the quiet window. The re-pin is a container-shrink
        //    correction, not a forced follow, so it is polled on the gap it
        //    restores rather than on a report.
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

    /// Tapping a suggested prompt under the last assistant message appends
}

extension ConversationTranscriptScrollUITests {
    /// the optimistic user row and the thinking indicator while the prompt
    /// rows disappear (the last message is now the user's). The transcript
    /// was resting at the bottom, so it must follow: once the send's forced
    /// follow has reported, Go to End must not be shown and the sent row and
    /// the thinking indicator must rest inside the transcript
    /// (intent-hq/ios#281, symptom 1). The indicator is the settled state's
    /// last row rather than a precondition waited for on its own: a fixed
    /// 5 s wait for it raced the follow on CI (intent-hq/ios#307), while a
    /// transcript that has settled without it is reported with the sent
    /// row's resting state.
    @MainActor
    func testTappingSuggestedPromptKeepsTranscriptAtBottomAndGoToEndHidden() {
        let app = launchDemoApp(hooksRowTriggerFile: hooksRowTriggerFile)
        let opened = openLongConversation(in: app)
        let transcript = opened.transcript

        // 1. Settled at the bottom with the prompt rows on screen.
        assertRestsAtBottom(
            lastRow: opened.lastMessage,
            named: "last assistant paragraph",
            endRow: EndRow.lastSuggestedPrompt(in: app),
            in: opened,
            context: "before tapping the suggested prompt"
        )
        let prompt = app.buttons[Fixture.firstSuggestedPromptIdentifier].firstMatch
        XCTAssertTrue(
            waitUntilVisible(prompt, in: transcript, timeout: 5),
            "first suggested prompt is not on screen while the transcript rests at the bottom — "
                + restingState(of: prompt, named: "prompt button", in: opened)
        )

        // 2. Tap it: the prompt rows collapse, the sent row and the thinking
        //    indicator appear as the new tail.
        prompt.tap()
        XCTAssertTrue(
            prompt.waitForNonExistence(timeout: 5),
            "suggested prompt rows stayed in the transcript after tapping one"
        )
        let sentRow = message(in: app, containing: Fixture.firstSuggestedPrompt)
        let thinkingIndicator = EndRow.thinkingIndicator(in: app)

        // 3. Still pinned: the send's forced follow reports with the
        //    indicator (now the final content row) at the end of the
        //    transcript, the sent row is on screen too, and both hold over
        //    the quiet window with no Go to End.
        guard waitUntilSettled(
            on: thinkingIndicator.element,
            named: thinkingIndicator.name,
            in: opened,
            context: "after tapping the suggested prompt",
            alsoReporting: (sentRow, "sent prompt row")
        ) else { return }
        assertAtEnd(thinkingIndicator, in: opened, context: "after tapping the suggested prompt")
        XCTAssertTrue(
            isVisible(sentRow, in: transcript),
            "sent prompt row is not on screen after the transcript settled on the thinking indicator — "
                + restingState(of: sentRow, named: "sent prompt row", in: opened)
        )
        assertStaysAtBottom(
            lastRow: thinkingIndicator.element,
            named: thinkingIndicator.name,
            endRow: thinkingIndicator,
            in: opened,
            context: "after tapping the suggested prompt"
        )
        XCTAssertTrue(
            isVisible(sentRow, in: transcript),
            "sent prompt row left the screen over the quiet window — "
                + restingState(of: sentRow, named: "sent prompt row", in: opened)
        )
    }

    /// Entering the conversation must land the transcript at the bottom
    /// every time: last row inside the transcript — neither above it (viewport
    /// past the end over a blank band, intent-hq/ios#271) nor below it (short
    /// of the end) — and no Go to End once layout settles. Both entry
    /// symptoms are intermittent, so the entry is repeated
    /// (intent-hq/ios#281, symptoms 2 and 3).
    @MainActor
    func testEnteringConversationRepeatedlyRestsAtBottomWithGoToEndHidden() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["INTENT_UITEST_TRANSCRIPT_CRASH_REPRO"] == "1",
            "Temporary quarantine for the unresolved app crash tracked at https://github.com/intent-hq/ios/issues/427; "
                + "opt in with TEST_RUNNER_INTENT_UITEST_TRANSCRIPT_CRASH_REPRO=1."
        )
        let app = launchDemoApp(hooksRowTriggerFile: hooksRowTriggerFile)
        let endRow = EndRow.lastSuggestedPrompt(in: app)
        for cycle in 1 ... Fixture.entryCycles {
            let opened = openLongConversation(in: app, context: "entry cycle \(cycle)")
            assertRestsAtBottom(
                lastRow: opened.lastMessage,
                named: "last assistant paragraph",
                endRow: endRow,
                in: opened,
                context: "entry cycle \(cycle)"
            )
            leaveConversation(in: app)
        }
    }
}

extension ConversationTranscriptScrollUITests {
    /// A cold entry — fresh launch, first open of the long conversation —
    /// must settle with the last message inside the transcript, over a
    /// non-empty visible band, having reached the very end: the last prompt
    /// row under the last message — the transcript's final content row — is
    /// laid out and rests `Fixture.endRowGap` above the bottom edge. A
    /// transcript that rests on the last message with the prompt rows never
    /// laid out is short of the end with Go to End hidden (the state the
    /// coordinator-shaped fixture reproduces on CI; intent-hq/ios#304); one
    /// whose end row sits higher than that is past the end over a blank band
    /// (intent-hq/ios#271). The checks run once the entry follow has
    /// reported and the last message holds still — its landing corrections
    /// are the follow's own work, not a symptom — and the end row must stay
    /// at the end with Go to End absent over the quiet window that follows.
    /// The symptom is intermittent (on CI it showed at cold entry in one run
    /// and only after a send in the next), so the cold entry is repeated — a
    /// fresh launch each cycle, as a return through the workspace list would
    /// mount the cached transcript.
    /// The hooks row is held back like everywhere else; here the test also
    /// asserts the gate held, as this is where its landing blanked the
    /// transcript on CI (intent-hq/ios#338; the "last paragraph not in the
    /// accessibility hierarchy" failure of intent-hq/ios#313 attempt 1).
    @MainActor
    func testFirstOpenOfLongConversationShowsLastMessageWithNoBlankBand() {
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

            // 1. Settled: the entry follow has reported and the last message
            //    rests inside the transcript. An unrealized last message (the
            //    viewport resting past the end) never satisfies this, and the
            //    visible band is walked for the failure message.
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
            //    At the end: the end row on screen, `endRowGap` above the
            //    bottom edge — neither the prompt rows below the viewport
            //    nor a blank band under them.
            assertAtEnd(
                endRow,
                in: opened,
                context: "\(context) (\(visibleBand.count) row(s) in the visible band)"
            )

            // 2. Go to End never appears over the quiet window, and the last
            //    message stays inside the transcript with the end row at the
            //    end throughout.
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

    /// From the very top of the long transcript a single tap on Go to End
    /// must land at the very end: the last message and the prompt rows under
    /// it come on screen with the end row `Fixture.endRowGap` above the
    /// bottom edge, the button disappears and stays gone over the quiet
    /// window — no second tap (intent-hq/ios#305).
    @MainActor
    func testGoToEndFromTopOfLongTranscriptLandsAtEndInOneTap() {
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
            context: "before scrolling to the top"
        )

        // 1. Scroll to the very top: swipe down (content moves down) until
        //    the first message is on screen.
        let firstMessage = message(in: app, containing: Fixture.firstMessageFragment)
        var swipes = 0
        while swipes < Fixture.maxSwipesToTop, !isVisible(firstMessage, in: transcript) {
            transcript.swipeDown(velocity: .fast)
            swipes += 1
        }
        XCTAssertTrue(
            waitUntilVisible(firstMessage, in: transcript, timeout: 5),
            "first message never came on screen after \(swipes) swipes towards the top — "
                + restingState(of: firstMessage, named: "first user paragraph", in: opened)
        )
        XCTAssertTrue(
            goToEnd.waitForExistence(timeout: 5),
            "Go to End is absent at the top of the transcript"
        )

        // 2. One tap, then no further interaction: the tap's forced follow
        //    reports with the last message resting inside the transcript
        //    and the end row at the end, the button goes, and both hold
        //    over the quiet window.
        goToEnd.tap()
        let context = "after one tap on Go to End from the top (after \(swipes) swipes)"
        guard waitUntilSettled(
            on: lastMessage,
            named: "last assistant paragraph",
            in: opened,
            context: context,
            alsoReporting: (endRow.element, endRow.name)
        ) else { return }
        XCTAssertTrue(
            goToEnd.waitForNonExistence(timeout: 5),
            "Go to End stayed visible after one tap from the top — "
                + restingState(of: lastMessage, named: "last assistant paragraph", in: opened)
        )
        assertAtEnd(endRow, in: opened, context: context)
        assertStaysAtBottom(
            lastRow: lastMessage,
            named: "last assistant paragraph",
            endRow: endRow,
            in: opened,
            context: context
        )
    }
}
