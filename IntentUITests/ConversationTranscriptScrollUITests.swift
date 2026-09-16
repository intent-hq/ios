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
/// (intent-hq/ios#304), and hidden after a single tap from the very top of
/// the transcript (intent-hq/ios#305).
///
/// Every wait is settlement polling on the app's own state, never a guessed
/// idle delay: a forced follow (entry, Go to End, a send) reports its
/// outcome in the transcript's accessibility value once its live geometry
/// has come to rest, and the last row is asserted inside the transcript
/// only once that report is in and the row's frame has held still
/// (`waitUntilSettled`). Sampling the geometry alone raced the follow: two
/// samples 0.25 s apart also agree while the follow waits out its debounce
/// or between two of its landing corrections, and the correction that then
/// ran moved the rows under the assertions (intent-hq/ios#313,
/// intent-hq/ios#307, intent-hq/intent#5109). Frames are read from single
/// snapshots (`frame(of:)`): `exists` followed by `frame` resolves the
/// query twice and a row the lazy stack derealizes in between fails the
/// test outright.
///
/// Every "rests at the bottom" failure message reports the follow's report,
/// whether Go to End is present and where the last row's frame lies
/// relative to the transcript's frame (ABOVE it: viewport past the end over
/// a blank band; BELOW it: viewport short of the end) so a CI failure is
/// diagnostic on its own (intent-hq/ios#281).
///
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

    /// The file the fixture's hooks-row gate waits on (see
    /// `Fixture.hooksRowTriggerFileArgumentPrefix`): one path per test
    /// (XCTest instantiates the case per test method), never created unless
    /// the test releases the row.
    private let hooksRowTriggerFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcript-hooks-row-\(UUID().uuidString).trigger")

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        try? FileManager.default.removeItem(at: hooksRowTriggerFile)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: hooksRowTriggerFile)
        try super.tearDownWithError()
    }

    private enum Fixture {
        static let workspaceTitle = "Deflake payment integration tests"
        // Distinctive substrings of DemoFixtures.longConversationFirstSentence
        // / longConversationLastSentence (the UI test target cannot import
        // the app module, so match on text the way AppStoreScreenshotTests does).
        static let firstMessageFragment = "Start of the flake investigation"
        static let lastMessageFragment = "End of the flake investigation"
        static let goToEndIdentifier = "transcript.goToEnd"
        // ConversationTranscriptView.suggestedPromptsView's first button, and
        // DemoFixtures.longConversationSuggestedPrompts[0] — the text of the
        // optimistic user row the tap appends.
        static let firstSuggestedPromptIdentifier = "transcript.suggestedPrompt.0"
        static let firstSuggestedPrompt = "Open a PR for the deflake changes"
        // The last of DemoFixtures.longConversationSuggestedPrompts (three
        // prompts): the transcript's final content row, 20 pt above the end
        // of the content (the bottom marker's spacer and padding). A
        // transcript resting with it inside its frame has reached the end;
        // one that stopped on the last message with the prompt rows still
        // below the viewport has not (#304, #305). The first prompt alone
        // cannot tell the two apart: it fits inside a viewport resting two
        // prompt rows short.
        static let endRowIdentifier = "transcript.suggestedPrompt.2"
        // ConversationTranscriptView.thinkingIndicatorView's label: the last
        // transcript row once a send is in flight (demo `agent.sendMessage`
        // answers `{}`, so the indicator stays and no reply ever streams).
        static let thinkingIndicatorLabel = "Thinking..."
        // Entry symptoms are intermittent; each cycle is a fresh entry.
        static let entryCycles = 5
        // Upper bound on a forced follow (entry, Go to End, a send) reporting
        // its outcome and the last row coming to rest inside the transcript.
        // The follow's own budget is bounded — a 100 ms debounce, the scroll
        // animation, then a 3 s landing timeout (Constants.Conversation.
        // Transcript.followLanding*) — so the margin beyond it covers only
        // the CI simulator realizing the 150+-message lazy stack around it;
        // a follow still unreported after this long is a hang, not slowness.
        static let settleTimeout: TimeInterval = 15
        // Window after the transcript has settled during which Go to End
        // must not appear and the last row must stay inside the transcript.
        // Outlasts an automatic follow that content re-measuring after the
        // report could still trigger (100 ms debounce + 300 ms completion)
        // and the follow's whole landing budget (see settleTimeout), so a
        // late correction or re-pin cannot hide behind it (#304, #305).
        static let quietWindow: TimeInterval = 3
        // The transcript's own ScrollView; the hooks row is a horizontal
        // ScrollView too, so `scrollViews.firstMatch` could resolve to it.
        static let transcriptIdentifier = "transcript.scrollView"
        // BackgroundHooksRow's fixed label, and DemoFixtures.longConversationHookName.
        static let hooksRowLabel = "Running hooks"
        static let hookName = "Wait for CI on flake fix"
        // Holds the hooks row back: the fixture waits for this file to exist
        // (polled every 100 ms). Every launch passes `hooksRowTriggerFile`;
        // only the footer test creates it, once it has recorded a steady
        // baseline, so in every other test the row cannot land inside the
        // windows (#338). The runner and the app share the simulator
        // filesystem, so a temporary-directory path works. A clock-based
        // delay raced the CI simulator's render time (#285).
        static let hooksRowTriggerFileArgumentPrefix = "--demo-hook-list-trigger-file="
        static let hooksRowTimeout: TimeInterval = 15
        // Slack for the last message to sit at the same distance from the
        // transcript's bottom edge after the re-pin as before the row (an
        // unpinned transcript is off by the row's full height, ~36 pt).
        static let rePinTolerance: CGFloat = 4
        // Upper bound on fast swipes to reach the first message from the
        // bottom of the 150+-message transcript; the loop exits as soon as
        // the first message is on screen.
        static let maxSwipesToTop = 150
        // Walks of the visible band before an empty band is reported; rows
        // (de)realizing between two queries can empty a single walk.
        static let visibleBandAttempts = 3
        // The transcript scroll view's accessibility value under --demo-data
        // (ConversationTranscriptScrollPolicy.forcedFollowLandingSummary):
        // `lastForcedFollow=pending` while a forced follow is in flight, then
        // `lastForcedFollow=<outcome> corrections=N`. The follow reports only
        // once two consecutive reads of its live geometry agree (or its
        // budget is spent), so the report is the app's own settlement
        // signal. The outcome itself is not asserted: on CI simulators the
        // budget runs out — `giveUp` — with the viewport at the end (#313
        // attempt 1, intent-hq/intent#5109), so the end is asserted on the
        // geometry of the end row instead and the report is carried in the
        // failure messages.
        static let followReportPrefix = "lastForcedFollow="
        static let pendingFollowReport = "lastForcedFollow=pending"
        // Cadence of every poll.
        static let pollInterval: TimeInterval = 0.25
    }

    /// The conversation's elements once the transcript has settled at the bottom.
    private struct OpenConversation {
        let lastMessage: XCUIElement
        let goToEnd: XCUIElement
        let transcript: XCUIElement
    }

    @MainActor
    func testGoToEndAppearsWhenScrolledUpAndHidesAtBottom() throws {
        let app = launchDemoApp()
        let opened = openLongConversation(in: app)
        let lastMessage = opened.lastMessage
        let goToEnd = opened.goToEnd
        let transcript = opened.transcript

        // 1. At rest at the bottom the button must stay hidden: the entry
        //    follow reports and the last message rests inside the transcript,
        //    then the button must not appear over the quiet window —
        //    waitForNonExistence would pass immediately before the transcript
        //    had measured anything.
        assertRestsAtBottom(
            lastRow: lastMessage, named: "last assistant paragraph",
            in: opened, context: "after opening")

        // 2. Scrolling up (content moves down) reveals it.
        for _ in 0..<3 { transcript.swipeDown() }
        XCTAssertTrue(
            goToEnd.waitForExistence(timeout: 5),
            "Go to End did not appear after scrolling the transcript up")

        // 3. Tapping it returns to the bottom and hides it: the tap's forced
        //    follow reports with the last message inside the transcript.
        goToEnd.tap()
        waitUntilSettled(
            on: lastMessage, named: "last assistant paragraph",
            in: opened, context: "after Go to End")
        XCTAssertTrue(
            goToEnd.waitForNonExistence(timeout: 5),
            "Go to End stayed visible after tapping it — "
                + restingState(of: lastMessage, named: "last assistant paragraph", in: opened))

        // 4. Scroll up again, then scroll back down by hand: the button must
        //    reappear and then hide without the tap path.
        for _ in 0..<3 { transcript.swipeDown() }
        XCTAssertTrue(
            goToEnd.waitForExistence(timeout: 5),
            "Go to End did not reappear after scrolling up a second time")
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
            "Go to End stayed visible after scrolling back to the bottom")
        XCTAssertTrue(
            waitUntilVisible(lastMessage, in: transcript, timeout: 5),
            "last transcript message is not visible after scrolling back to the bottom")
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
        let app = launchDemoApp()
        let opened = openLongConversation(in: app)
        let lastMessage = opened.lastMessage
        let goToEnd = opened.goToEnd
        let transcript = opened.transcript

        // 1. Settle at the bottom while the hooks row is held back by the
        //    trigger file: the entry follow has reported and the last message
        //    rests inside the transcript, so the baseline gap is not a sample
        //    taken during a still-animating follow or its landing retry.
        waitUntilSettled(
            on: lastMessage, named: "last assistant paragraph",
            in: opened, context: "before the hooks row")
        let hooksRow = app.staticTexts[Fixture.hooksRowLabel].firstMatch
        XCTAssertFalse(
            hooksRow.exists,
            "hooks row was already present when the transcript settled; the fixture trigger file did not hold it back")
        let bottomBeforeRow = transcript.frame.maxY
        let gapToBottom = { transcript.frame.maxY - (self.frame(of: lastMessage)?.maxY ?? .nan) }
        guard let gapBeforeRow = waitUntilSteady(timeout: 5, tolerance: Fixture.rePinTolerance, gapToBottom) else {
            return XCTFail("transcript kept moving after it settled; no steady baseline gap — "
                + restingState(of: lastMessage, named: "last assistant paragraph", in: opened))
        }
        XCTAssertFalse(
            hooksRow.exists,
            "hooks row was already present when the baseline gap was recorded; the fixture trigger file did not hold it back")

        // 2. Release the hooks row; it appears and shrinks the transcript from below.
        try Data().write(to: hooksRowTriggerFile)
        XCTAssertTrue(
            hooksRow.waitForExistence(timeout: Fixture.hooksRowTimeout),
            "hooks row never appeared under the transcript after the trigger file was created")
        let hookChip = app.descendants(matching: .any)
            .containing(NSPredicate(format: "label CONTAINS %@", Fixture.hookName))
            .firstMatch
        XCTAssertTrue(
            hookChip.waitForExistence(timeout: 5),
            "hook chip never appeared in the hooks row")
        XCTAssertTrue(
            waitUntil(timeout: 5) { transcript.frame.maxY < bottomBeforeRow },
            "transcript did not shrink when the hooks row appeared (\(transcript.frame.maxY) vs \(bottomBeforeRow))")

        // 3. Re-pinned: the last message sits at the same distance from the
        //    (new) bottom edge as before the row, then no Go to End and the
        //    last message inside the transcript over the quiet window. The
        //    re-pin is a container-shrink correction, not a forced follow, so
        //    it is polled on the gap it restores rather than on a report.
        var gapAfterRow = gapToBottom()
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                gapAfterRow = gapToBottom()
                return abs(gapAfterRow - gapBeforeRow) <= Fixture.rePinTolerance
            },
            "transcript did not re-pin to the bottom after the hooks row appeared: "
                + "last message sat \(gapAfterRow) pt above the bottom edge, \(gapBeforeRow) pt before the row — "
                + restingState(of: lastMessage, named: "last assistant paragraph", in: opened))
        assertStaysAtBottom(
            lastRow: lastMessage, named: "last assistant paragraph",
            in: opened, context: "after the hooks row shrank the transcript")
    }

    /// Tapping a suggested prompt under the last assistant message appends
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
    func testTappingSuggestedPromptKeepsTranscriptAtBottomAndGoToEndHidden() throws {
        let app = launchDemoApp()
        let opened = openLongConversation(in: app)
        let transcript = opened.transcript

        // 1. Settled at the bottom with the prompt rows on screen.
        assertRestsAtBottom(
            lastRow: opened.lastMessage, named: "last assistant paragraph",
            in: opened, context: "before tapping the suggested prompt")
        let prompt = app.buttons[Fixture.firstSuggestedPromptIdentifier].firstMatch
        XCTAssertTrue(
            waitUntilVisible(prompt, in: transcript, timeout: 5),
            "first suggested prompt is not on screen while the transcript rests at the bottom — "
                + restingState(of: prompt, named: "prompt button", in: opened))

        // 2. Tap it: the prompt rows collapse, the sent row and the thinking
        //    indicator appear as the new tail.
        prompt.tap()
        XCTAssertTrue(
            prompt.waitForNonExistence(timeout: 5),
            "suggested prompt rows stayed in the transcript after tapping one")
        let sentRow = message(in: app, containing: Fixture.firstSuggestedPrompt)
        let thinkingIndicator = app.staticTexts[Fixture.thinkingIndicatorLabel].firstMatch

        // 3. Still pinned: the send's forced follow reports with the
        //    indicator (the last row) inside the transcript, the sent row is
        //    on screen too, and both hold over the quiet window with no Go
        //    to End.
        guard waitUntilSettled(
            on: thinkingIndicator, named: "thinking indicator",
            in: opened, context: "after tapping the suggested prompt",
            alsoReporting: (sentRow, "sent prompt row")
        ) else { return }
        XCTAssertTrue(
            isVisible(sentRow, in: transcript),
            "sent prompt row is not on screen after the transcript settled on the thinking indicator — "
                + restingState(of: sentRow, named: "sent prompt row", in: opened))
        assertStaysAtBottom(
            lastRow: thinkingIndicator, named: "thinking indicator",
            in: opened, context: "after tapping the suggested prompt")
        XCTAssertTrue(
            isVisible(sentRow, in: transcript),
            "sent prompt row left the screen over the quiet window — "
                + restingState(of: sentRow, named: "sent prompt row", in: opened))
    }

    /// Entering the conversation must land the transcript at the bottom
    /// every time: last row inside the transcript — neither above it (viewport
    /// past the end over a blank band, intent-hq/ios#271) nor below it (short
    /// of the end) — and no Go to End once layout settles. Both entry
    /// symptoms are intermittent, so the entry is repeated
    /// (intent-hq/ios#281, symptoms 2 and 3).
    @MainActor
    func testEnteringConversationRepeatedlyRestsAtBottomWithGoToEndHidden() throws {
        let app = launchDemoApp()
        for cycle in 1...Fixture.entryCycles {
            let opened = openLongConversation(in: app, context: "entry cycle \(cycle)")
            assertRestsAtBottom(
                lastRow: opened.lastMessage, named: "last assistant paragraph",
                in: opened, context: "entry cycle \(cycle)")
            leaveConversation(in: app)
        }
    }

    /// A cold entry — fresh launch, first open of the long conversation —
    /// must settle with the last message inside the transcript, over a
    /// non-empty visible band, having reached the very end: the last prompt
    /// row under the last message — the transcript's final content row — is
    /// laid out and on screen too. A transcript that rests on the last
    /// message with the prompt rows never laid out is short of the end with
    /// Go to End hidden (the state the coordinator-shaped fixture reproduces
    /// on CI; intent-hq/ios#304). The checks run once the entry follow has
    /// reported and the last message holds still — its landing corrections
    /// are the follow's own work, not a symptom — and the end row must stay
    /// on screen with Go to End absent over the quiet window that follows.
    /// The symptom is intermittent (on CI it showed at cold entry in one run
    /// and only after a send in the next), so the cold entry is repeated — a
    /// fresh launch each cycle, as a return through the workspace list would
    /// mount the cached transcript.
    ///
    /// The hooks row is held back like everywhere else; here the test also
    /// asserts the gate held, as this is where its landing blanked the
    /// transcript on CI (intent-hq/ios#338; the "last paragraph not in the
    /// accessibility hierarchy" failure of intent-hq/ios#313 attempt 1).
    @MainActor
    func testFirstOpenOfLongConversationShowsLastMessageWithNoBlankBand() throws {
        for cycle in 1...Fixture.entryCycles {
            let context = "cold entry \(cycle)/\(Fixture.entryCycles)"
            let app = launchDemoApp()
            let opened = enterLongConversation(in: app, context: context)
            let lastMessage = opened.lastMessage
            let transcript = opened.transcript
            let endRow = app.buttons[Fixture.endRowIdentifier].firstMatch

            // 1. Settled: the entry follow has reported and the last message
            //    rests inside the transcript. An unrealized last message (the
            //    viewport resting past the end) never satisfies this, and the
            //    visible band is walked for the failure message.
            let settled = waitUntilSettled(
                on: lastMessage, named: "last assistant paragraph",
                in: opened, context: context,
                alsoReporting: (endRow, "last suggested prompt"))
            let visibleBand = rows(intersecting: transcript)
            XCTAssertFalse(
                visibleBand.isEmpty,
                "\(context): the transcript's visible band is empty — no message row intersects the transcript frame — "
                    + restingState(of: lastMessage, named: "last assistant paragraph", in: opened))
            guard settled else {
                app.terminate()
                continue
            }
            XCTAssertTrue(
                isInside(endRow, transcript),
                "\(context): the settled transcript is short of the end — the prompt rows under the last message "
                    + "are not on screen (\(visibleBand.count) row(s) in the visible band) — "
                    + restingState(of: endRow, named: "last suggested prompt", in: opened))

            // 2. Go to End never appears over the quiet window, and the last
            //    message and the end row are still on screen at the end of it.
            assertStaysAtBottom(
                lastRow: lastMessage, named: "last assistant paragraph",
                in: opened, context: context)
            XCTAssertTrue(
                isInside(endRow, transcript),
                "\(context): the transcript is short of the end after the quiet window — "
                    + restingState(of: endRow, named: "last suggested prompt", in: opened))
            XCTAssertFalse(
                app.staticTexts[Fixture.hooksRowLabel].exists,
                "\(context): the hooks row landed during the cold entry; the fixture trigger file did not hold it back")
            app.terminate()
        }
    }

    /// From the very top of the long transcript a single tap on Go to End
    /// must land at the very end: the last message and the prompt rows under
    /// it come on screen, the button disappears and stays gone over the quiet
    /// window — no second tap (intent-hq/ios#305).
    @MainActor
    func testGoToEndFromTopOfLongTranscriptLandsAtEndInOneTap() throws {
        let app = launchDemoApp()
        let opened = openLongConversation(in: app)
        let lastMessage = opened.lastMessage
        let goToEnd = opened.goToEnd
        let transcript = opened.transcript
        let endRow = app.buttons[Fixture.endRowIdentifier].firstMatch
        assertRestsAtBottom(
            lastRow: lastMessage, named: "last assistant paragraph",
            in: opened, context: "before scrolling to the top")

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
                + restingState(of: firstMessage, named: "first user paragraph", in: opened))
        XCTAssertTrue(
            goToEnd.waitForExistence(timeout: 5),
            "Go to End is absent at the top of the transcript")

        // 2. One tap, then no further interaction: the tap's forced follow
        //    reports with the last message resting inside the transcript,
        //    the button goes, and both hold over the quiet window with the
        //    end row on screen.
        goToEnd.tap()
        guard waitUntilSettled(
            on: lastMessage, named: "last assistant paragraph",
            in: opened, context: "after one tap on Go to End from the top (after \(swipes) swipes)",
            alsoReporting: (endRow, "last suggested prompt")
        ) else { return }
        XCTAssertTrue(
            goToEnd.waitForNonExistence(timeout: 5),
            "Go to End stayed visible after one tap from the top — "
                + restingState(of: lastMessage, named: "last assistant paragraph", in: opened))
        XCTAssertTrue(
            isInside(endRow, transcript),
            "one tap from the top stopped short of the end: the prompt rows under the last message are not "
                + "on screen — " + restingState(of: endRow, named: "last suggested prompt", in: opened))
        assertStaysAtBottom(
            lastRow: lastMessage, named: "last assistant paragraph",
            in: opened, context: "after one tap on Go to End from the top")
        XCTAssertTrue(
            isInside(endRow, transcript),
            "the transcript left the end over the quiet window after one tap from the top — "
                + restingState(of: endRow, named: "last suggested prompt", in: opened))
    }

    // MARK: - Helpers

    /// Launches the demo app with the hooks row held back behind
    /// `hooksRowTriggerFile` (see the class comment).
    @MainActor
    private func launchDemoApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--demo-data",
            Fixture.hooksRowTriggerFileArgumentPrefix + hooksRowTriggerFile.path,
        ]
        app.launch()
        return app
    }

    /// Taps the long-conversation workspace row and waits for its transcript,
    /// Go to End button handle and scroll view. A missing last message is
    /// reported with the resting state (a viewport past the end may leave the
    /// last row unrealized and off the accessibility hierarchy).
    @MainActor
    private func openLongConversation(in app: XCUIApplication, context: String = "after opening") -> OpenConversation {
        let opened = enterLongConversation(in: app, context: context)
        XCTAssertTrue(
            opened.lastMessage.waitForExistence(timeout: 15),
            "\(context): last transcript message never appeared — "
                + restingState(of: opened.lastMessage, named: "last assistant paragraph", in: opened))
        return opened
    }

    /// `openLongConversation` without waiting for the last message, so a
    /// test can observe the transcript's very first settled state.
    @MainActor
    private func enterLongConversation(in app: XCUIApplication, context: String) -> OpenConversation {
        let workspaceRow = app.staticTexts[Fixture.workspaceTitle].firstMatch
        if !workspaceRow.waitForExistence(timeout: 30) {
            // Same fallback as AppStoreScreenshotTests: a collapsed iPad
            // sidebar hides the workspace list behind the first nav button.
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(workspaceRow.waitForExistence(timeout: 15))
        }
        workspaceRow.tap()

        let lastMessage = message(in: app, containing: Fixture.lastMessageFragment)
        let goToEnd = app.buttons[Fixture.goToEndIdentifier].firstMatch
        let transcript = app.scrollViews[Fixture.transcriptIdentifier].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 5), "\(context): transcript scroll view not found")
        return OpenConversation(lastMessage: lastMessage, goToEnd: goToEnd, transcript: transcript)
    }

    /// The transcript's static-text rows whose frames intersect its own
    /// frame: empty when the viewport rests over a blank band. The hierarchy
    /// is in flux while a cold entry (de)realizes rows, so each row's frame
    /// is read from one snapshot (`frame(of:)`) and skipped when the row has
    /// vanished rather than queried from a stale index, and an empty walk is
    /// retried a few times.
    @MainActor
    private func rows(intersecting transcript: XCUIElement) -> [XCUIElement] {
        let rows = transcript.staticTexts
        for _ in 0..<Fixture.visibleBandAttempts {
            let transcriptFrame = transcript.frame
            var intersecting: [XCUIElement] = []
            for index in 0..<rows.count {
                let row = rows.element(boundBy: index)
                if let rowFrame = frame(of: row), rowFrame.intersects(transcriptFrame) {
                    intersecting.append(row)
                }
            }
            if !intersecting.isEmpty { return intersecting }
            RunLoop.current.run(until: Date().addingTimeInterval(Fixture.pollInterval))
        }
        return []
    }

    /// Navigates back out of the transcript to the workspace list so the
    /// next `openLongConversation` is a fresh entry; relaunches when no back
    /// path leads there (a split view keeps the transcript in its detail column).
    @MainActor
    private func leaveConversation(in app: XCUIApplication) {
        let workspaceRow = app.staticTexts[Fixture.workspaceTitle].firstMatch
        var backTapsLeft = 2
        while backTapsLeft > 0, !workspaceRow.waitForExistence(timeout: 3) {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.exists else { break }
            back.tap()
            backTapsLeft -= 1
        }
        if !workspaceRow.waitForExistence(timeout: 5) {
            app.launch()
        }
    }

    /// Asserts the transcript rests at the bottom with `lastRow` as its last
    /// row: `waitUntilSettled` and then `assertStaysAtBottom`.
    @MainActor
    private func assertRestsAtBottom(
        lastRow: XCUIElement, named rowName: String, in opened: OpenConversation, context: String
    ) {
        guard waitUntilSettled(on: lastRow, named: rowName, in: opened, context: context) else { return }
        assertStaysAtBottom(lastRow: lastRow, named: rowName, in: opened, context: context)
    }

    /// The one settlement wait. Polls until the transcript has come to rest
    /// with `lastRow` at its end: the last forced follow has reported an
    /// outcome (the accessibility value is no longer `pending`), the row's
    /// frame lies inside the transcript's frame, and the row has held still
    /// across two consecutive polls. A row the lazy stack has not realized
    /// (viewport past the end) never satisfies this. Fails the test — with
    /// the follow's report and the resting state of the row and of
    /// `alsoReporting` — when that does not happen within
    /// `Fixture.settleTimeout`, and returns whether it did so callers can
    /// stop instead of asserting on a transcript still in motion.
    @MainActor @discardableResult
    private func waitUntilSettled(
        on lastRow: XCUIElement, named rowName: String, in opened: OpenConversation, context: String,
        alsoReporting extra: (row: XCUIElement, name: String)? = nil
    ) -> Bool {
        let transcript = opened.transcript
        var previousMaxY: CGFloat = .nan
        let settled = waitUntil(timeout: Fixture.settleTimeout) {
            guard followHasReported(in: opened), let rowFrame = frame(of: lastRow) else {
                previousMaxY = .nan
                return false
            }
            let held = abs(rowFrame.maxY - previousMaxY) <= Fixture.rePinTolerance
            previousMaxY = rowFrame.maxY
            return held && isInside(rowFrame, transcript)
        }
        if !settled {
            var message = "\(context): transcript did not settle on the \(rowName) within "
                + "\(Int(Fixture.settleTimeout)) s — " + restingState(of: lastRow, named: rowName, in: opened)
            if let extra {
                message += "; " + restingState(of: extra.row, named: extra.name, in: opened)
            }
            XCTFail(message)
        }
        return settled
    }

    /// Over `Fixture.quietWindow` after the transcript has settled, Go to
    /// End must never appear and `lastRow` must stay inside the transcript's
    /// frame: a late correction, re-pin or automatic follow that moves the
    /// rows shows up here. The failure message carries `restingState`.
    @MainActor
    private func assertStaysAtBottom(
        lastRow: XCUIElement, named rowName: String, in opened: OpenConversation, context: String
    ) {
        let transcript = opened.transcript
        let goToEnd = opened.goToEnd
        let broke = waitUntil(timeout: Fixture.quietWindow) {
            goToEnd.exists || !isInside(lastRow, transcript)
        }
        XCTAssertFalse(
            broke,
            "\(context): transcript left the bottom within the quiet window after settling — "
                + restingState(of: lastRow, named: rowName, in: opened))
    }

    /// The transcript's accessibility value: the last forced follow's report
    /// (see `Fixture.followReportPrefix`), or a placeholder when absent.
    @MainActor
    private func followReport(in opened: OpenConversation) -> String {
        (opened.transcript.value as? String) ?? "<no transcript value>"
    }

    /// True once the last forced follow has reported an outcome — not while
    /// one is in flight or before the entry follow has started.
    @MainActor
    private func followHasReported(in opened: OpenConversation) -> Bool {
        let report = followReport(in: opened)
        return report.hasPrefix(Fixture.followReportPrefix) && report != Fixture.pendingFollowReport
    }

    /// The element's frame from a single snapshot; nil when the element is
    /// not in the accessibility hierarchy or has no size. `exists` followed
    /// by `frame` resolves the query twice, and a lazy-stack row that
    /// derealizes in between fails the test instead of reading as absent.
    @MainActor
    private func frame(of element: XCUIElement) -> CGRect? {
        guard let frame = (try? element.snapshot())?.frame, !frame.isEmpty else { return nil }
        return frame
    }

    /// True when the element's whole frame lies inside the container's frame
    /// (within `rePinTolerance` for rounding).
    @MainActor
    private func isInside(_ element: XCUIElement, _ container: XCUIElement) -> Bool {
        guard let elementFrame = frame(of: element) else { return false }
        return isInside(elementFrame, container)
    }

    @MainActor
    private func isInside(_ frame: CGRect, _ container: XCUIElement) -> Bool {
        container.frame.insetBy(dx: 0, dy: -Fixture.rePinTolerance).contains(frame)
    }

    /// Diagnostic sentence for failure messages: the last forced follow's
    /// report, Go to End presence and where `row`'s frame lies relative to
    /// the transcript's frame — ABOVE it means the viewport rests past the
    /// end (blank band), BELOW it means the viewport rests short of the end.
    @MainActor
    private func restingState(of row: XCUIElement, named rowName: String, in opened: OpenConversation) -> String {
        let transcriptFrame = opened.transcript.frame
        let state = "\(followReport(in: opened)); " + (opened.goToEnd.exists ? "Go to End PRESENT" : "Go to End absent")
        guard let rowFrame = frame(of: row) else {
            return "\(state); \(rowName) is not in the accessibility hierarchy (unrealized / off screen); "
                + "transcript frame \(transcriptFrame)"
        }
        let position: String
        if rowFrame.maxY <= transcriptFrame.minY {
            position = "ABOVE the transcript (viewport rests past the end)"
        } else if rowFrame.minY >= transcriptFrame.maxY {
            position = "BELOW the transcript (viewport rests short of the end)"
        } else if isInside(rowFrame, opened.transcript) {
            position = "inside the transcript"
        } else if rowFrame.minY < transcriptFrame.minY {
            position = "clipped by the transcript's top edge (partly past the end)"
        } else {
            position = "clipped by the transcript's bottom edge (partly short of the end)"
        }
        return "\(state); \(rowName) frame \(rowFrame) is \(position); transcript frame \(transcriptFrame)"
    }

    @MainActor
    private func message(in app: XCUIApplication, containing fragment: String) -> XCUIElement {
        app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS[c] %@", fragment))
            .firstMatch
    }

    /// True once the element's centre lies inside the container's frame.
    /// `isHittable` is not used: the transcript's selectable text is backed
    /// by a text-view accessibility element overlapping the paragraphs, and
    /// whether a hit test at a paragraph's centre resolves to the paragraph or
    /// to that overlay varies between runs while the paragraph is on screen.
    @MainActor
    private func waitUntilVisible(
        _ element: XCUIElement, in container: XCUIElement, timeout: TimeInterval
    ) -> Bool {
        waitUntil(timeout: timeout) { isVisible(element, in: container) }
    }

    /// True when the element exists and its centre lies inside the
    /// container's frame right now.
    @MainActor
    private func isVisible(_ element: XCUIElement, in container: XCUIElement) -> Bool {
        guard let elementFrame = frame(of: element) else { return false }
        return container.frame.contains(CGPoint(x: elementFrame.midX, y: elementFrame.midY))
    }

    /// Polls `condition` every `Fixture.pollInterval` until it holds or
    /// `timeout` elapses.
    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(Fixture.pollInterval))
        } while Date() < deadline
        return false
    }

    /// Samples `value` every `Fixture.pollInterval` and returns it once two
    /// consecutive samples agree within `tolerance`; nil if that never
    /// happens before `timeout` elapses (a NaN sample never agrees).
    @MainActor
    private func waitUntilSteady(
        timeout: TimeInterval, tolerance: CGFloat, _ value: () -> CGFloat
    ) -> CGFloat? {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = value()
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(Fixture.pollInterval))
            let current = value()
            if abs(current - previous) <= tolerance { return current }
            previous = current
        } while Date() < deadline
        return nil
    }
}
