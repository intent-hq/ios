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

    /// The file whose contents set the short conversation's code block line
    /// count (see `Fixture.growthFileArgumentPrefix`): one path per test,
    /// never written unless the test grows the reply.
    private let growthFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcript-short-growth-\(UUID().uuidString).count")

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        try? FileManager.default.removeItem(at: hooksRowTriggerFile)
        try? FileManager.default.removeItem(at: growthFile)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: hooksRowTriggerFile)
        try? FileManager.default.removeItem(at: growthFile)
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
        // prompts): the transcript's final content row while no send is in
        // flight. A transcript resting with it inside its frame, `endRowGap`
        // above the bottom edge, has reached the end; one that stopped on the
        // last message with the prompt rows still below the viewport has not
        // (#304, #305). The first prompt alone cannot tell the two apart: it
        // fits inside a viewport resting two prompt rows short.
        static let endRowIdentifier = "transcript.suggestedPrompt.2"
        // ConversationTranscriptView.thinkingIndicatorView's label: the last
        // transcript row once a send is in flight (demo `agent.sendMessage`
        // answers `{}`, so the indicator stays and no reply ever streams).
        // The label sits inside the row's `.padding(.vertical, 4)`, so its
        // frame's bottom edge is that much above the row's.
        static let thinkingIndicatorLabel = "Thinking..."
        static let thinkingIndicatorLabelInset: CGFloat = 4
        // Where the final content row's bottom edge rests above the
        // transcript's bottom edge when the viewport is at the end: the
        // LazyVStack's 16 pt spacing, then the `scroll-bottom` marker's 8 pt
        // spacer and 12 pt bottom padding (ConversationTranscriptView). The
        // transcript sits above the footer rows and the composer in
        // ConversationColumnView's VStack, so it has no bottom content inset
        // to add. Containment alone accepts a viewport stalled past the end
        // — the last rows inside, a blank band below them, Go to End hidden
        // — so the gap is bounded on both sides: larger is a blank band,
        // smaller is the marker (and rows under it) short of the viewport.
        static let endRowGap: CGFloat = 36
        // Slack on `endRowGap`: the follow lands within 1 pt
        // (Constants.Conversation.Transcript.followLandingTolerance) and
        // accessibility frames round to the pixel grid.
        static let endGapTolerance: CGFloat = 4
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

        // The short conversation (intent-hq/ios#346): DemoFixtures.
        // shortConversationWorkspaceTitle, a distinctive substring of
        // shortConversationLastSentence, and its single suggested prompt —
        // its final content row.
        static let shortWorkspaceTitle = "Rename the nightly billing cron"
        static let shortLastMessageFragment = "End of the cron rename"
        static let shortEndRowIdentifier = "transcript.suggestedPrompt.0"
        // Sets the reply's code block line count: the fixture reads the
        // file's contents on every conversation fetch and polls it (every
        // 100 ms); a change is streamed to the open conversation the way a
        // live reply is — one chat delta per added line, a terminal delta,
        // then the stream's end. `<count> burst=<lines>` paces the last
        // `lines` deltas against the automatic follow (see
        // DemoFixtures.shortConversationGrowthBurstInterval). Every launch
        // passes `growthFile`; only the growth test writes it (see the class
        // comment on the hooks row trigger file for why a file, not a clock).
        static let growthFileArgumentPrefix = "--demo-short-conversation-growth-file="
        static let growthBurstToken = "burst="
        // DemoFixtures.shortConversationBaselineLineCount: the code block's
        // lines while the file is absent.
        static let shortBaselineLineCount = 2
        // Lines added first, while the transcript stays short of one page,
        // to measure one code line's height on this simulator: the fixture
        // cannot know the container, and a line height guessed from a font
        // size would miss the band on another device or text size.
        static let calibrationLines = 3
        // Bounds on one code line's height. With `calibrationLines` and
        // `calibrationRoomMargin`, the upper bound is the room the short
        // transcript must leave below its end row for the calibration
        // growth to stay short of one page.
        static let maxLineHeight: CGFloat = 28
        static let minLineHeight: CGFloat = 8
        static let calibrationRoomMargin: CGFloat = 20
        // Constants.Conversation.Transcript.atBottomThreshold: the growth
        // past one page must stay under it (no Go to End, no away edge) and
        // over `endGapTolerance` (a rest that far short must fail
        // `isAtEnd`).
        static let atBottomThreshold: CGFloat = 50
        // Code lines streamed past the fold as the growth's burst, one line
        // fewer when that many would leave the band. The first crosses the
        // fold; its delta's follow check still reads the geometry laid out
        // before it, so the second's requests the automatic follow, and the
        // third lands while that follow is in flight — the line the pre-fix
        // viewport rested short by (#346). Two lines can only show the
        // footer swap that ends the stream landing in flight.
        static let pastFoldLines = 3
        // Upper bound on a written line count reaching the transcript: the
        // fixture's 100 ms poll, the deltas streaming in 80 ms apart, the
        // burst's lead pause, and the grown row re-laying out.
        static let growthTimeout: TimeInterval = 15
    }

    /// The conversation's elements once the transcript has settled at the bottom.
    private struct OpenConversation {
        let lastMessage: XCUIElement
        let goToEnd: XCUIElement
        let transcript: XCUIElement
    }

    /// The transcript's final content row — the row whose gap from the
    /// bottom edge is `Fixture.endRowGap` when the viewport is at the end —
    /// and how far its accessibility frame's bottom edge sits above the
    /// row's own (a label inside a padded row).
    private struct EndRow {
        let element: XCUIElement
        let name: String
        let labelInset: CGFloat

        @MainActor
        static func lastSuggestedPrompt(in app: XCUIApplication) -> EndRow {
            EndRow(
                element: app.buttons[Fixture.endRowIdentifier].firstMatch,
                name: "last suggested prompt", labelInset: 0)
        }

        /// The short conversation's single suggested prompt.
        @MainActor
        static func onlySuggestedPrompt(in app: XCUIApplication) -> EndRow {
            EndRow(
                element: app.buttons[Fixture.shortEndRowIdentifier].firstMatch,
                name: "suggested prompt", labelInset: 0)
        }

        @MainActor
        static func thinkingIndicator(in app: XCUIApplication) -> EndRow {
            EndRow(
                element: app.staticTexts[Fixture.thinkingIndicatorLabel].firstMatch,
                name: "thinking indicator", labelInset: Fixture.thinkingIndicatorLabelInset)
        }
    }

    @MainActor
    func testGoToEndAppearsWhenScrolledUpAndHidesAtBottom() throws {
        let app = launchDemoApp()
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
            lastRow: lastMessage, named: "last assistant paragraph", endRow: endRow,
            in: opened, context: "after opening")

        // 2. Scrolling up (content moves down) reveals it.
        for _ in 0..<3 { transcript.swipeDown() }
        XCTAssertTrue(
            goToEnd.waitForExistence(timeout: 5),
            "Go to End did not appear after scrolling the transcript up")

        // 3. Tapping it returns to the bottom and hides it: the tap's forced
        //    follow reports with the last message inside the transcript and
        //    the end row at the end.
        goToEnd.tap()
        guard waitUntilSettled(
            on: lastMessage, named: "last assistant paragraph",
            in: opened, context: "after Go to End",
            alsoReporting: (endRow.element, endRow.name)
        ) else { return }
        assertAtEnd(endRow, in: opened, context: "after Go to End")
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
        let endRow = EndRow.lastSuggestedPrompt(in: app)

        // 1. Settle at the bottom while the hooks row is held back by the
        //    trigger file: the entry follow has reported and the last message
        //    rests inside the transcript with the end row at the end, so the
        //    baseline gap is not a sample taken during a still-animating
        //    follow or its landing retry, nor one of a viewport past the end.
        guard waitUntilSettled(
            on: lastMessage, named: "last assistant paragraph",
            in: opened, context: "before the hooks row",
            alsoReporting: (endRow.element, endRow.name)
        ) else { return }
        assertAtEnd(endRow, in: opened, context: "before the hooks row")
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
                + restingState(of: lastMessage, named: "last assistant paragraph", in: opened))
        assertStaysAtBottom(
            lastRow: lastMessage, named: "last assistant paragraph", endRow: endRow,
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
            endRow: EndRow.lastSuggestedPrompt(in: app),
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
        let thinkingIndicator = EndRow.thinkingIndicator(in: app)

        // 3. Still pinned: the send's forced follow reports with the
        //    indicator (now the final content row) at the end of the
        //    transcript, the sent row is on screen too, and both hold over
        //    the quiet window with no Go to End.
        guard waitUntilSettled(
            on: thinkingIndicator.element, named: thinkingIndicator.name,
            in: opened, context: "after tapping the suggested prompt",
            alsoReporting: (sentRow, "sent prompt row")
        ) else { return }
        assertAtEnd(thinkingIndicator, in: opened, context: "after tapping the suggested prompt")
        XCTAssertTrue(
            isVisible(sentRow, in: transcript),
            "sent prompt row is not on screen after the transcript settled on the thinking indicator — "
                + restingState(of: sentRow, named: "sent prompt row", in: opened))
        assertStaysAtBottom(
            lastRow: thinkingIndicator.element, named: thinkingIndicator.name, endRow: thinkingIndicator,
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
        let endRow = EndRow.lastSuggestedPrompt(in: app)
        for cycle in 1...Fixture.entryCycles {
            let opened = openLongConversation(in: app, context: "entry cycle \(cycle)")
            assertRestsAtBottom(
                lastRow: opened.lastMessage, named: "last assistant paragraph", endRow: endRow,
                in: opened, context: "entry cycle \(cycle)")
            leaveConversation(in: app)
        }
    }

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
            let endRow = EndRow.lastSuggestedPrompt(in: app)

            // 1. Settled: the entry follow has reported and the last message
            //    rests inside the transcript. An unrealized last message (the
            //    viewport resting past the end) never satisfies this, and the
            //    visible band is walked for the failure message.
            let settled = waitUntilSettled(
                on: lastMessage, named: "last assistant paragraph",
                in: opened, context: context,
                alsoReporting: (endRow.element, endRow.name))
            let visibleBand = rows(intersecting: transcript)
            XCTAssertFalse(
                visibleBand.isEmpty,
                "\(context): the transcript's visible band is empty — no message row intersects the transcript frame — "
                    + restingState(of: lastMessage, named: "last assistant paragraph", in: opened))
            guard settled else {
                app.terminate()
                continue
            }
            //    At the end: the end row on screen, `endRowGap` above the
            //    bottom edge — neither the prompt rows below the viewport
            //    nor a blank band under them.
            assertAtEnd(
                endRow, in: opened,
                context: "\(context) (\(visibleBand.count) row(s) in the visible band)")

            // 2. Go to End never appears over the quiet window, and the last
            //    message stays inside the transcript with the end row at the
            //    end throughout.
            assertStaysAtBottom(
                lastRow: lastMessage, named: "last assistant paragraph", endRow: endRow,
                in: opened, context: context)
            XCTAssertFalse(
                app.staticTexts[Fixture.hooksRowLabel].exists,
                "\(context): the hooks row landed during the cold entry; the fixture trigger file did not hold it back")
            app.terminate()
        }
    }

    /// From the very top of the long transcript a single tap on Go to End
    /// must land at the very end: the last message and the prompt rows under
    /// it come on screen with the end row `Fixture.endRowGap` above the
    /// bottom edge, the button disappears and stays gone over the quiet
    /// window — no second tap (intent-hq/ios#305).
    @MainActor
    func testGoToEndFromTopOfLongTranscriptLandsAtEndInOneTap() throws {
        let app = launchDemoApp()
        let opened = openLongConversation(in: app)
        let lastMessage = opened.lastMessage
        let goToEnd = opened.goToEnd
        let transcript = opened.transcript
        let endRow = EndRow.lastSuggestedPrompt(in: app)
        assertRestsAtBottom(
            lastRow: lastMessage, named: "last assistant paragraph", endRow: endRow,
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
        //    reports with the last message resting inside the transcript
        //    and the end row at the end, the button goes, and both hold
        //    over the quiet window.
        goToEnd.tap()
        let context = "after one tap on Go to End from the top (after \(swipes) swipes)"
        guard waitUntilSettled(
            on: lastMessage, named: "last assistant paragraph",
            in: opened, context: context,
            alsoReporting: (endRow.element, endRow.name)
        ) else { return }
        XCTAssertTrue(
            goToEnd.waitForNonExistence(timeout: 5),
            "Go to End stayed visible after one tap from the top — "
                + restingState(of: lastMessage, named: "last assistant paragraph", in: opened))
        assertAtEnd(endRow, in: opened, context: context)
        assertStaysAtBottom(
            lastRow: lastMessage, named: "last assistant paragraph", endRow: endRow,
            in: opened, context: context)
    }

    /// A conversation that opens shorter than the screen and whose reply then
    /// grows the transcript to just past one page — by less than the
    /// at-bottom band, so Go to End never shows and no away edge fires — must
    /// come to rest at the end: the end row at its end gap, Go to End hidden,
    /// and both holding over the quiet window (intent-hq/ios#346). Before the
    /// fix the viewport rested a line or two short of the end with nothing to
    /// close the gap.
    ///
    /// The growth is the fixture's code block gaining lines through
    /// `growthFile`, streamed to the store the way a live reply is: one chat
    /// delta per line under the streaming flag, then the stream ending. How
    /// far past one page it lands is aimed, not guessed: the free room below the
    /// end row is measured on the settled short transcript, a first growth
    /// that keeps it short measures one code line's height on this
    /// simulator, and the final line count is chosen from both so that the
    /// lines still fitting stream first and `Fixture.pastFoldLines` cross
    /// the fold as the burst the fixture paces against the automatic follow.
    @MainActor
    func testShortConversationGrowingPastOnePageRestsAtBottomWithGoToEndHidden() throws {
        let app = launchDemoApp()
        let opened = openShortConversation(in: app)
        let lastMessage = opened.lastMessage
        let transcript = opened.transcript
        let endRow = EndRow.onlySuggestedPrompt(in: app)
        let roomBelowEndRow = { self.freeRoom(below: endRow, in: transcript) }

        // 1. Settle short of one page: the entry follow has reported and the
        //    last message rests inside the transcript. The room between the
        //    end row's end gap and the bottom edge is what the growth has to
        //    fill; it must be there (a transcript already at one page, or one
        //    not resting at the top, cannot run this scenario) and hold room
        //    for the calibration growth to stay short.
        guard waitUntilSettled(
            on: lastMessage, named: "last assistant paragraph",
            in: opened, context: "before the reply grew",
            alsoReporting: (endRow.element, endRow.name)
        ) else { return }
        XCTAssertFalse(
            opened.goToEnd.exists,
            "Go to End is shown on the short transcript — " + restingState(of: lastMessage, named: "last assistant paragraph", in: opened))
        guard let shortRoom = waitUntilSteady(timeout: 5, tolerance: Fixture.rePinTolerance, roomBelowEndRow) else {
            return XCTFail("the short transcript kept moving after it settled; no steady free room below the end row — "
                + restingState(of: endRow.element, named: endRow.name, in: opened))
        }
        let calibrationRoom = CGFloat(Fixture.calibrationLines) * Fixture.maxLineHeight + Fixture.calibrationRoomMargin
        guard shortRoom >= calibrationRoom else {
            return XCTFail("the short transcript leaves \(shortRoom) pt free below the end row, under the "
                + "\(calibrationRoom) pt the calibration growth needs to stay short of one page: the fixture reply "
                + "must be shorter, or the short content is not resting at the top — "
                + restingState(of: endRow.element, named: endRow.name, in: opened))
        }

        // 2. Calibrate: grow by a few lines that keep the transcript short and
        //    read one code line's height off how much room they took.
        var lineCount = Fixture.shortBaselineLineCount + Fixture.calibrationLines
        try grow(to: lineCount)
        guard let calibratedRoom = waitUntilRoomChanged(
            from: shortRoom, roomBelowEndRow, below: endRow, in: opened, context: "after the calibration growth"
        ) else { return }
        let lineHeight = (shortRoom - calibratedRoom) / CGFloat(Fixture.calibrationLines)
        guard lineHeight >= Fixture.minLineHeight, lineHeight <= Fixture.maxLineHeight, calibratedRoom > 0 else {
            return XCTFail("the calibration growth of \(Fixture.calibrationLines) code lines took the free room from "
                + "\(shortRoom) to \(calibratedRoom) pt (\(lineHeight) pt per line), outside what one code line can measure — "
                + restingState(of: endRow.element, named: endRow.name, in: opened))
        }

        // 3. Grow past one page: the lines that still fit, then
        //    `pastFoldLines` as the burst — inside the at-bottom band, well
        //    past `isAtEnd`'s tolerance — or one fewer when the band has no
        //    room for that many.
        let fittingLines = Int((calibratedRoom / lineHeight).rounded(.down))
        var burstLines = Fixture.pastFoldLines
        var overshoot = CGFloat(fittingLines + burstLines) * lineHeight - calibratedRoom
        if overshoot >= Fixture.atBottomThreshold - Fixture.rePinTolerance {
            burstLines -= 1
            overshoot -= lineHeight
        }
        let extraLines = fittingLines + burstLines
        guard overshoot > Fixture.endGapTolerance + Fixture.rePinTolerance,
              overshoot < Fixture.atBottomThreshold - Fixture.rePinTolerance else {
            return XCTFail("\(extraLines) more code lines of \(lineHeight) pt would grow the transcript \(overshoot) pt past "
                + "one page, outside the at-bottom band this scenario needs")
        }
        lineCount += extraLines
        try grow(to: lineCount, burst: burstLines)

        // 4. Rests at the end, then stays: the growth's within-band edge
        //    re-pins the viewport, so the end row comes to its end gap with
        //    Go to End hidden and holds over the quiet window. The re-pin
        //    is an automatic follow, not a forced one, so it is polled on
        //    the geometry it restores rather than on a report.
        let context = "after the reply grew the transcript \(Int(overshoot.rounded())) pt past one page "
            + "(\(lineCount) code lines of \(lineHeight) pt, the last \(burstLines) as the burst)"
        XCTAssertTrue(
            waitUntil(timeout: Fixture.settleTimeout) { isAtEnd(endRow, in: transcript) },
            "\(context): the transcript did not come to rest at the end within \(Int(Fixture.settleTimeout)) s — "
                + restingState(of: endRow.element, named: endRow.name, in: opened) + "; "
                + restingState(of: lastMessage, named: "last assistant paragraph", in: opened))
        assertStaysAtBottom(
            lastRow: lastMessage, named: "last assistant paragraph", endRow: endRow,
            in: opened, context: context)
    }

    // MARK: - Helpers

    /// Launches the demo app with the hooks row held back behind
    /// `hooksRowTriggerFile` and the short conversation's growth bound to
    /// `growthFile` (see the class comment and `Fixture.growthFileArgumentPrefix`).
    @MainActor
    private func launchDemoApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--demo-data",
            Fixture.hooksRowTriggerFileArgumentPrefix + hooksRowTriggerFile.path,
            Fixture.growthFileArgumentPrefix + growthFile.path,
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

    /// `openLongConversation` for the short conversation (intent-hq/ios#346).
    @MainActor
    private func openShortConversation(in app: XCUIApplication, context: String = "after opening") -> OpenConversation {
        let opened = enterConversation(
            in: app, workspaceTitle: Fixture.shortWorkspaceTitle,
            lastMessageFragment: Fixture.shortLastMessageFragment, context: context)
        XCTAssertTrue(
            opened.lastMessage.waitForExistence(timeout: 15),
            "\(context): last transcript message of the short conversation never appeared — "
                + restingState(of: opened.lastMessage, named: "last assistant paragraph", in: opened))
        return opened
    }

    /// `openLongConversation` without waiting for the last message, so a
    /// test can observe the transcript's very first settled state.
    @MainActor
    private func enterLongConversation(in app: XCUIApplication, context: String) -> OpenConversation {
        enterConversation(
            in: app, workspaceTitle: Fixture.workspaceTitle,
            lastMessageFragment: Fixture.lastMessageFragment, context: context)
    }

    /// Taps the workspace row titled `workspaceTitle` (a workspace whose
    /// single foreground agent opens straight into its transcript) and waits
    /// for the transcript scroll view; the last message and Go to End are
    /// returned as handles without waiting for them.
    @MainActor
    private func enterConversation(
        in app: XCUIApplication, workspaceTitle: String, lastMessageFragment: String, context: String
    ) -> OpenConversation {
        let workspaceRow = app.staticTexts[workspaceTitle].firstMatch
        if !workspaceRow.waitForExistence(timeout: 30) {
            // Same fallback as AppStoreScreenshotTests: a collapsed iPad
            // sidebar hides the workspace list behind the first nav button.
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(workspaceRow.waitForExistence(timeout: 15))
        }
        workspaceRow.tap()

        let lastMessage = message(in: app, containing: lastMessageFragment)
        let goToEnd = app.buttons[Fixture.goToEndIdentifier].firstMatch
        let transcript = app.scrollViews[Fixture.transcriptIdentifier].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 5), "\(context): transcript scroll view not found")
        return OpenConversation(lastMessage: lastMessage, goToEnd: goToEnd, transcript: transcript)
    }

    /// Sets the short conversation's code block line count, the last `burst`
    /// lines paced as the burst: the fixture picks the change up within its
    /// poll interval and streams it to the open transcript. Written
    /// atomically so the fixture never reads a half-written count.
    private func grow(to lineCount: Int, burst: Int = 0) throws {
        let contents = burst > 0
            ? "\(lineCount) \(Fixture.growthBurstToken)\(burst)" : String(lineCount)
        try Data(contents.utf8).write(to: growthFile, options: .atomic)
    }

    /// Points between the end of the content — `endRow`'s frame bottom plus
    /// its end gap — and the transcript's bottom edge: positive while the
    /// content is shorter than one page and resting at the top, 0 at the
    /// end, negative when the end row rests below the bottom edge (short of
    /// the end); NaN while the row is not realized.
    @MainActor
    private func freeRoom(below endRow: EndRow, in transcript: XCUIElement) -> CGFloat {
        guard let rowFrame = frame(of: endRow.element) else { return .nan }
        return transcript.frame.maxY - (rowFrame.maxY + Fixture.endRowGap + endRow.labelInset)
    }

    /// Waits for a growth to reach the transcript — `freeRoom` moving off
    /// `previous` by more than `rePinTolerance` — and then for it to hold
    /// still across two polls, returning the settled value. Fails the test
    /// (with `endRow`'s resting state) and returns nil when either does not
    /// happen in time.
    @MainActor
    private func waitUntilRoomChanged(
        from previous: CGFloat, _ freeRoom: () -> CGFloat, below endRow: EndRow, in opened: OpenConversation,
        context: String
    ) -> CGFloat? {
        guard waitUntil(timeout: Fixture.growthTimeout, { abs(freeRoom() - previous) > Fixture.rePinTolerance }) else {
            XCTFail("\(context): the transcript did not grow within \(Int(Fixture.growthTimeout)) s of writing the "
                + "growth file; the free room below the end row stayed at \(previous) pt — "
                + restingState(of: endRow.element, named: endRow.name, in: opened))
            return nil
        }
        guard let settled = waitUntilSteady(timeout: 5, tolerance: Fixture.rePinTolerance, freeRoom) else {
            XCTFail("\(context): the transcript kept moving after it grew; no steady free room below the end row — "
                + restingState(of: endRow.element, named: endRow.name, in: opened))
            return nil
        }
        return settled
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

    /// Asserts the transcript rests at the end with `lastRow` as its last
    /// row: `waitUntilSettled`, then `assertAtEnd` on `endRow`, then
    /// `assertStaysAtBottom`.
    @MainActor
    private func assertRestsAtBottom(
        lastRow: XCUIElement, named rowName: String, endRow: EndRow, in opened: OpenConversation, context: String
    ) {
        guard waitUntilSettled(
            on: lastRow, named: rowName, in: opened, context: context,
            alsoReporting: (endRow.element, endRow.name)
        ) else { return }
        assertAtEnd(endRow, in: opened, context: context)
        assertStaysAtBottom(lastRow: lastRow, named: rowName, endRow: endRow, in: opened, context: context)
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

    /// The settled transcript's outcome check, independent of what the
    /// follow reported: `endRow` rests at the end (`isAtEnd`). The follow's
    /// report is synchronization only — on CI simulators it is `giveUp`
    /// with the viewport at the end — so a `giveUp` that left the viewport
    /// stalled past the end, the last rows inside over a blank band with Go
    /// to End hidden, is caught here rather than by containment.
    @MainActor
    private func assertAtEnd(_ endRow: EndRow, in opened: OpenConversation, context: String) {
        XCTAssertTrue(
            isAtEnd(endRow, in: opened.transcript),
            "\(context): the settled transcript is not at the end — the \(endRow.name), its final content row, "
                + "does not rest \(Int(Fixture.endRowGap + endRow.labelInset)) ± \(Int(Fixture.endGapTolerance)) pt "
                + "above the bottom edge — " + restingState(of: endRow.element, named: endRow.name, in: opened))
    }

    /// Over `Fixture.quietWindow` after the transcript has settled, Go to
    /// End must never appear, `lastRow` must stay inside the transcript's
    /// frame and `endRow` must stay at the end: a late correction, re-pin
    /// or automatic follow that moves the rows shows up here. The failure
    /// message carries `restingState`.
    @MainActor
    private func assertStaysAtBottom(
        lastRow: XCUIElement, named rowName: String, endRow: EndRow, in opened: OpenConversation, context: String
    ) {
        let transcript = opened.transcript
        let goToEnd = opened.goToEnd
        let broke = waitUntil(timeout: Fixture.quietWindow) {
            goToEnd.exists || !isInside(lastRow, transcript) || !isAtEnd(endRow, in: transcript)
        }
        XCTAssertFalse(
            broke,
            "\(context): transcript left the end within the quiet window after settling — "
                + restingState(of: lastRow, named: rowName, in: opened) + "; "
                + restingState(of: endRow.element, named: endRow.name, in: opened))
    }

    /// True when `endRow` is realized, lies inside the transcript and its
    /// frame's bottom edge sits `Fixture.endRowGap` (plus the row's label
    /// inset) above the transcript's bottom edge, within
    /// `Fixture.endGapTolerance`: the viewport is at the end — not short of
    /// it with the marker (or rows) below, not past it over a blank band.
    @MainActor
    private func isAtEnd(_ endRow: EndRow, in transcript: XCUIElement) -> Bool {
        guard let rowFrame = frame(of: endRow.element), isInside(rowFrame, transcript) else { return false }
        let gap = transcript.frame.maxY - rowFrame.maxY
        return abs(gap - (Fixture.endRowGap + endRow.labelInset)) <= Fixture.endGapTolerance
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
    /// end (blank band), BELOW it means the viewport rests short of the end
    /// — with the row's gap from the transcript's bottom edge.
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
        let gap = transcriptFrame.maxY - rowFrame.maxY
        return "\(state); \(rowName) frame \(rowFrame) is \(position), its bottom edge \(gap) pt above "
            + "the transcript's; transcript frame \(transcriptFrame)"
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
