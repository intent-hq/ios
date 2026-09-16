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
/// (intent-hq/ios#304), hidden — with the last message still on screen —
/// when the hooks row lands right after a cold entry has settled
/// (intent-hq/ios#338), still hidden — with the last message still on
/// screen — when a slim-truncated tool row near the end hydrates seconds
/// after a cold or warm entry has settled (intent-hq/ios#338, device
/// evidence), and hidden after a single tap from the very top of the
/// transcript (intent-hq/ios#305).
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
/// the hooks row never lands on its own clock: only the two footer tests
/// release it, once the transcript has been observed settled. On its
/// default clock the row lands ~4 s after entry, inside every test's
/// settle and quiet windows, and a row landing right after an entry had
/// settled left the transcript blank with Go to End hidden on CI
/// (intent-hq/ios#338) — a second event, a container resize, with its own
/// outcome, in tests that measure the entry, a tap or a send. The cold-entry
/// footer test reproduces exactly that event on purpose.
nonisolated final class ConversationTranscriptScrollUITests: XCTestCase {

    /// The file the fixture's hooks-row gate waits on (see
    /// `Fixture.hooksRowTriggerFileArgumentPrefix`): one path per test
    /// (XCTest instantiates the case per test method), never created unless
    /// the test releases the row.
    private let hooksRowTriggerFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcript-hooks-row-\(UUID().uuidString).trigger")

    /// The file the fixture's block-hydration gate waits on (see
    /// `Fixture.blockHydrationTriggerFileArgumentPrefix`): every launch
    /// passes it, so a slim-truncated tool row a test expands hydrates only
    /// once the test creates the file.
    private let blockHydrationTriggerFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcript-block-hydration-\(UUID().uuidString).trigger")

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        try? FileManager.default.removeItem(at: hooksRowTriggerFile)
        try? FileManager.default.removeItem(at: blockHydrationTriggerFile)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: hooksRowTriggerFile)
        try? FileManager.default.removeItem(at: blockHydrationTriggerFile)
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
        // only the two footer tests create it, once the transcript has
        // settled, so in every other test the row cannot land inside the
        // windows (#338). The runner and the app share the simulator
        // filesystem, so a temporary-directory path works. A clock-based
        // delay raced the CI simulator's render time (#285).
        static let hooksRowTriggerFileArgumentPrefix = "--demo-hook-list-trigger-file="
        static let hooksRowTimeout: TimeInterval = 15
        // Holds the slim-truncated tool rows' `agent.getMessageBlock`
        // hydration back the same way (DemoFixtures.longConversationBlockHydrationGate).
        static let blockHydrationTriggerFileArgumentPrefix = "--demo-block-hydration-trigger-file="
        static let blockHydrationTimeout: TimeInterval = 15
        // Where the fixture seats the slim tool rows
        // (DemoFixtures.LongConversationSlimToolRowLayout). By default they
        // open the last assistant text messages — the layout that reproduced
        // #338 through the hooks-row tests (CI run 35100409278) — so every
        // test but the hydration one runs against it. The hydration test
        // needs to tap the row, which a text-bearing assistant row's copy
        // context-menu overlay prevents (intent-hq/ios#344), so it asks for
        // the rows as tool-only assistant messages right before the text.
        static let slimToolRowLayoutArgumentPrefix = "--demo-long-slim-tool-rows="
        static let standaloneSlimToolRows = "standalone"
        // File name of the `view` tool row that goes with the last message
        // (DemoFixtures.longConversationTruncatedToolCalls[0]): its header
        // reads "Read final_evidence_table.py tests/payments/evidence"
        // (ToolClassifier), and its result is a slim preview until hydrated.
        static let truncatedToolFileName = "final_evidence_table.py"
        // ToolCallView's hydration hint under an expanded slim row: "Preview
        // — tap to load full content" until the fetch starts, "Loading full
        // content…" while it is held by the gate, gone once the full block
        // has merged in.
        static let hydrationHintFragment = "full content"
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
        // The entry follow's report in #338: it had landed, and the
        // container re-pin that blanked the transcript is not a forced
        // follow, so the report never changes while the viewport is blank.
        static let landedFollowReportPrefix = "lastForcedFollow=landed"
        // Cadence of every poll.
        static let pollInterval: TimeInterval = 0.25
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

    /// The hooks row landing right after a cold entry has settled — the
    /// timing of intent-hq/ios#338 — must leave the transcript populated:
    /// the row shrinks the container by its height and the re-pin that
    /// follows must keep the last message realized inside the transcript,
    /// with Go to End hidden and the entry follow's report untouched
    /// (`lastForcedFollow=landed`: the re-pin is not a forced follow). On CI
    /// the row landed on its default clock a couple of seconds after the
    /// entry follow had reported, and from that moment the scroll view's
    /// content container realized no rows at all — a blank viewport, no Go
    /// to End, no recovery — while the report still read `landed`. Here the
    /// row is released through the trigger-file gate the instant
    /// `waitUntilSettled` returns, so the sequence is reproduced on the
    /// fixture's own settlement signal rather than on a clock. The symptom
    /// showed on the second launch of the process in a run, so the cold
    /// entry is repeated with a fresh launch each cycle; the gate is closed
    /// again before every launch.
    @MainActor
    func testHooksRowLandingRightAfterColdEntryKeepsLastMessageOnScreen() throws {
        for cycle in 1...Fixture.entryCycles {
            let context = "cold entry \(cycle)/\(Fixture.entryCycles) with the hooks row released on settle"
            try? FileManager.default.removeItem(at: hooksRowTriggerFile)
            let app = launchDemoApp()
            let opened = enterLongConversation(in: app, context: context)
            let lastMessage = opened.lastMessage
            let transcript = opened.transcript
            let endRow = EndRow.lastSuggestedPrompt(in: app)
            let hooksRow = app.staticTexts[Fixture.hooksRowLabel].firstMatch

            // 1. Settled exactly as a cold entry does: the entry follow has
            //    reported and the last message rests inside the transcript,
            //    with the row still held back.
            guard waitUntilSettled(
                on: lastMessage, named: "last assistant paragraph",
                in: opened, context: context,
                alsoReporting: (endRow.element, endRow.name)
            ) else {
                app.terminate()
                continue
            }
            XCTAssertFalse(
                hooksRow.exists,
                "\(context): the hooks row was already present when the transcript settled; the fixture trigger file did not hold it back")
            let bottomBeforeRow = transcript.frame.maxY

            // 2. Release the row right away; it lands and shrinks the
            //    transcript from below.
            try Data().write(to: hooksRowTriggerFile)
            XCTAssertTrue(
                hooksRow.waitForExistence(timeout: Fixture.hooksRowTimeout),
                "\(context): hooks row never appeared under the transcript after the trigger file was created")
            XCTAssertTrue(
                waitUntil(timeout: 5) { transcript.frame.maxY < bottomBeforeRow },
                "\(context): transcript did not shrink when the hooks row appeared (\(transcript.frame.maxY) vs \(bottomBeforeRow))")

            // 3. Still populated: the last message is realized inside the
            //    shrunk transcript once the re-pin has run (a blank viewport
            //    leaves it out of the accessibility hierarchy for good), Go
            //    to End is absent, the entry follow still reports `landed`,
            //    and the end row rests at the end over the quiet window.
            let repopulated = waitUntil(timeout: 5) { isInside(lastMessage, transcript) }
            let visibleBand = rows(intersecting: transcript)
            XCTAssertTrue(
                repopulated,
                "\(context): the last assistant paragraph is not inside the transcript after the hooks row landed "
                    + "(\(visibleBand.count) row(s) in the visible band) — "
                    + restingState(of: lastMessage, named: "last assistant paragraph", in: opened))
            XCTAssertFalse(
                opened.goToEnd.exists,
                "\(context): Go to End appeared after the hooks row landed — "
                    + restingState(of: lastMessage, named: "last assistant paragraph", in: opened))
            let report = followReport(in: opened)
            XCTAssertTrue(
                report.hasPrefix(Fixture.landedFollowReportPrefix),
                "\(context): the entry follow does not report landed after the hooks row landed — \(report)")
            assertAtEnd(endRow, in: opened, context: "\(context), after the hooks row shrank the transcript")
            assertStaysAtBottom(
                lastRow: lastMessage, named: "last assistant paragraph", endRow: endRow,
                in: opened, context: "\(context), after the hooks row shrank the transcript")
            app.terminate()
        }
    }

    /// The device reproduction of intent-hq/ios#338: the transcript has
    /// settled at the end — on a cold entry or a warm re-entry — and
    /// seconds later, on a slow network, a slim-truncated block near the end
    /// hydrates and its row re-measures under the resting viewport. Here a
    /// tool-only assistant message right before the last one (the
    /// `standalone` layout, see `Fixture.slimToolRowLayoutArgumentPrefix`)
    /// carries a `view` tool row whose result the
    /// fixture serves as a bounded preview; the test expands it once the
    /// entry has settled (the row grows by its expanded preview and the
    /// hydration fetch starts, held by the trigger-file gate), lets the
    /// transcript come to rest again, then releases the hydration: the full
    /// listing merges in (`remergeHydratedBlocks`) and the row grows to its
    /// output cap while the loading hint disappears. Afterwards the last
    /// paragraph must still be realized inside the transcript, Go to End
    /// absent, the follow report `landed`, and the end row at the end over
    /// the quiet window. The first cycle is a cold entry; each later cycle
    /// leaves through the workspace list and re-enters, the warm path the
    /// device reproduces on; the gate is closed again before every entry.
    ///
    /// Under `--demo-data` the store is rebuilt on every entry and there is
    /// no chat channel or reconnect, so the slim `agent.getConversation`
    /// answer is always the initial load (delaying it only shows the
    /// loading spinner longer); the late hydration is the content-change
    /// path the fixture can stage after the follow has landed.
    ///
    /// Skipped unless `INTENT_UITEST_BLOCK_HYDRATION=1`: the row cannot be
    /// expanded from the resting end position on the CI simulator. Opening
    /// the last text message, the copy context-menu overlay claims the tap
    /// (intent-hq/ios#344; CI run 35103923565); as a tool-only message right
    /// before it, the row rests under the navigation bar (frame y ≈ 49 in a
    /// transcript whose frame starts at 0; runs 35107741728, 35108439891,
    /// 35108448945, 35108458017), so the tap never reaches it either.
    @MainActor
    func testLateBlockHydrationNearEndAfterEntryKeepsLastMessageOnScreen() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["INTENT_UITEST_BLOCK_HYDRATION"] == "1",
            "the slim tool row cannot be tapped from the resting end position: intent-hq/ios#344 "
                + "(overlay) with leading rows, under the navigation bar with standalone rows")
        let app = launchDemoApp(standaloneSlimToolRows: true)
        let endRow = EndRow.lastSuggestedPrompt(in: app)
        for cycle in 1...Fixture.entryCycles {
            let entry = cycle == 1 ? "cold entry" : "warm re-entry"
            let context = "\(entry) \(cycle)/\(Fixture.entryCycles) with a late hydration near the end"
            try? FileManager.default.removeItem(at: blockHydrationTriggerFile)
            let opened = openLongConversation(in: app, context: context)
            let lastMessage = opened.lastMessage
            let transcript = opened.transcript
            let hydrationHint = app.descendants(matching: .any)
                .containing(NSPredicate(format: "label CONTAINS %@", Fixture.hydrationHintFragment))
                .firstMatch

            // 1. Settled at the end with the hydration gate closed and the
            //    tool row still collapsed.
            guard waitUntilSettled(
                on: lastMessage, named: "last assistant paragraph",
                in: opened, context: context,
                alsoReporting: (endRow.element, endRow.name)
            ) else {
                leaveConversation(in: app)
                continue
            }
            assertAtEnd(endRow, in: opened, context: context)
            XCTAssertFalse(
                hydrationHint.exists,
                "\(context): the slim tool row was already expanded when the transcript settled")

            // 2. Expand the slim tool row right above the last message: the row grows
            //    by its expanded preview and its hydration starts, held back
            //    by the trigger file. Let the transcript rest again so the
            //    hydration lands on a settled viewport, as on the device.
            //    The scroll view extends under the navigation bar, so the
            //    row must also clear the bar's bottom edge to be tappable.
            let toolRow = app.buttons
                .containing(NSPredicate(format: "label CONTAINS %@", Fixture.truncatedToolFileName))
                .firstMatch
            let navigationBarBottom = app.navigationBars.firstMatch.frame.maxY
            XCTAssertTrue(
                waitUntil(timeout: 5) {
                    isVisible(toolRow, in: transcript) && (frame(of: toolRow)?.minY ?? -.infinity) >= navigationBarBottom
                },
                "\(context): the slim tool row above the last message is not tappable while the transcript rests at the end "
                    + "(navigation bar bottom \(navigationBarBottom)) — "
                    + restingState(of: toolRow, named: "slim tool row", in: opened))
            toolRow.tap()
            XCTAssertTrue(
                hydrationHint.waitForExistence(timeout: 5),
                "\(context): the hydration hint never appeared under the expanded slim tool row — "
                    + restingState(of: toolRow, named: "slim tool row", in: opened))
            guard waitUntilSettled(
                on: lastMessage, named: "last assistant paragraph",
                in: opened, context: "\(context), after expanding the slim tool row",
                alsoReporting: (endRow.element, endRow.name)
            ) else {
                leaveConversation(in: app)
                continue
            }
            assertAtEnd(endRow, in: opened, context: "\(context), after expanding the slim tool row")
            XCTAssertTrue(
                hydrationHint.exists,
                "\(context): the hydration completed before the trigger file was created; the fixture gate did not hold it back")

            // 3. Release the hydration: the full listing merges in, the hint
            //    disappears and the row re-measures under the resting viewport.
            try Data().write(to: blockHydrationTriggerFile)
            XCTAssertTrue(
                waitUntil(timeout: Fixture.blockHydrationTimeout) { !hydrationHint.exists },
                "\(context): the hydration hint stayed after the trigger file was created; the full block never merged in")

            // 4. Still populated: the last paragraph is realized inside the
            //    transcript (a blank viewport leaves it out of the
            //    accessibility hierarchy for good), Go to End is absent, the
            //    follow still reports `landed`, and the end row rests at the
            //    end over the quiet window.
            let hydrated = "\(context), after the hydration re-measured the row"
            let repopulated = waitUntil(timeout: 5) { isInside(lastMessage, transcript) }
            let visibleBand = rows(intersecting: transcript)
            XCTAssertTrue(
                repopulated,
                "\(hydrated): the last assistant paragraph is not inside the transcript "
                    + "(\(visibleBand.count) row(s) in the visible band) — "
                    + restingState(of: lastMessage, named: "last assistant paragraph", in: opened))
            XCTAssertFalse(
                opened.goToEnd.exists,
                "\(hydrated): Go to End appeared — "
                    + restingState(of: lastMessage, named: "last assistant paragraph", in: opened))
            assertAtEnd(endRow, in: opened, context: hydrated)
            let report = followReport(in: opened)
            XCTAssertTrue(
                report.hasPrefix(Fixture.landedFollowReportPrefix),
                "\(hydrated): the follow does not report landed — \(report)")
            assertStaysAtBottom(
                lastRow: lastMessage, named: "last assistant paragraph", endRow: endRow,
                in: opened, context: hydrated)
            leaveConversation(in: app)
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

    // MARK: - Helpers

    /// Launches the demo app with the hooks row held back behind
    /// `hooksRowTriggerFile` (see the class comment) and the slim tool rows'
    /// hydration behind `blockHydrationTriggerFile`; `standaloneSlimToolRows`
    /// seats those rows as tool-only messages (see `Fixture`).
    @MainActor
    private func launchDemoApp(standaloneSlimToolRows: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--demo-data",
            Fixture.hooksRowTriggerFileArgumentPrefix + hooksRowTriggerFile.path,
            Fixture.blockHydrationTriggerFileArgumentPrefix + blockHydrationTriggerFile.path,
        ]
        if standaloneSlimToolRows {
            app.launchArguments.append(Fixture.slimToolRowLayoutArgumentPrefix + Fixture.standaloneSlimToolRows)
        }
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
