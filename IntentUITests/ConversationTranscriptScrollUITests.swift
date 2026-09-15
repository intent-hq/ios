import XCTest

/// Guards the "Go to End" affordance of the conversation transcript against
/// `--demo-data` fixtures: hidden while resting at the bottom, shown once the
/// user scrolls up, hidden again after tapping it or scrolling back down,
/// still hidden — with the last message still on screen — when a footer row
/// (the background-hooks chip row) appears under the settled transcript,
/// still hidden after tapping a suggested prompt under the last message,
/// hidden on every one of several consecutive entries into the conversation,
/// hidden — with the last message on screen and no blank band — at the first
/// settled sample of a cold entry (intent-hq/ios#304), and hidden after a
/// single tap from the very top of the transcript (intent-hq/ios#305).
///
/// Every "rests at the bottom" failure message reports whether Go to End is
/// present and where the last row's frame lies relative to the transcript's
/// frame (ABOVE it: viewport past the end over a blank band; BELOW it:
/// viewport short of the end) so a CI failure is diagnostic on its own
/// (intent-hq/ios#281).
///
/// Runs under the `Intent` scheme (`scripts/xcodebuild.sh test-ios`, CI).
/// The transcript is the coordinator-shaped, 150+-message
/// `DemoFixtures.longConversationMessages` (tool-call groups, agent-to-agent
/// rows, code fences, tables) served for the "Deflake payment integration
/// tests" workspace, whose single foreground agent opens straight into the
/// transcript from the workspace row with the "Waiting for all" footer
/// already under it. That workspace's `hook.list` fixture waits on
/// `DemoFixtures.longConversationHookListGate` — a delay by default, or a
/// trigger file the test creates — so its hooks row lands only after the
/// transcript has been observed settled.
nonisolated final class ConversationTranscriptScrollUITests: XCTestCase {

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
        // ConversationTranscriptView.thinkingIndicatorView's label: the last
        // transcript row once a send is in flight (demo `agent.sendMessage`
        // answers `{}`, so the indicator stays and no reply ever streams).
        static let thinkingIndicatorLabel = "Thinking..."
        // Entry symptoms are intermittent; each cycle is a fresh entry.
        static let entryCycles = 5
        // Window during which Go to End must not appear and the last row
        // must stay inside the transcript once it has settled; outlasts the
        // follow's completion timer and its landing retries.
        static let settleWindow: TimeInterval = 3
        // The transcript's own ScrollView; the hooks row is a horizontal
        // ScrollView too, so `scrollViews.firstMatch` could resolve to it.
        static let transcriptIdentifier = "transcript.scrollView"
        // BackgroundHooksRow's fixed label, and DemoFixtures.longConversationHookName.
        static let hooksRowLabel = "Running hooks"
        static let hookName = "Wait for CI on flake fix"
        // The footer test holds the hooks row back until it has recorded a
        // steady baseline: the fixture waits for this file to exist (polled
        // every 100 ms) and the test creates it. The runner and the app share
        // the simulator filesystem, so a temporary-directory path works. A
        // clock-based delay raced the CI simulator's render time (#285).
        static let hooksRowTriggerFileArgumentPrefix = "--demo-hook-list-trigger-file="
        static let hooksRowTimeout: TimeInterval = 15
        // Slack for the last message to sit at the same distance from the
        // transcript's bottom edge after the re-pin as before the row (an
        // unpinned transcript is off by the row's full height, ~36 pt).
        static let rePinTolerance: CGFloat = 4
        // Window after the first settled sample of a cold entry, and after a
        // single Go to End tap has landed, during which the button must not
        // (re)appear (#304, #305).
        static let quietWindow: TimeInterval = 2
        // Upper bound on fast swipes to reach the first message from the
        // bottom of the 150+-message transcript; the loop exits as soon as
        // the first message is on screen.
        static let maxSwipesToTop = 150
    }

    /// The conversation's elements once the transcript has settled at the bottom.
    private struct OpenConversation {
        let lastMessage: XCUIElement
        let goToEnd: XCUIElement
        let transcript: XCUIElement
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testGoToEndAppearsWhenScrolledUpAndHidesAtBottom() throws {
        let app = launchDemoApp()
        let opened = openLongConversation(in: app)
        let lastMessage = opened.lastMessage
        let goToEnd = opened.goToEnd
        let transcript = opened.transcript

        // 1. At rest at the bottom the button must stay hidden. Wait for the
        //    initial scroll to land (last message on screen), then require the
        //    button not to appear over a window that outlasts the scroll
        //    settle delays — waitForNonExistence would pass immediately
        //    before the transcript had measured anything.
        XCTAssertTrue(
            waitUntilVisible(lastMessage, in: transcript, timeout: 10),
            "transcript did not settle on the last message after opening")
        XCTAssertFalse(
            goToEnd.waitForExistence(timeout: 2),
            "Go to End is visible while the transcript rests at the bottom")

        // 2. Scrolling up (content moves down) reveals it.
        for _ in 0..<3 { transcript.swipeDown() }
        XCTAssertTrue(
            goToEnd.waitForExistence(timeout: 5),
            "Go to End did not appear after scrolling the transcript up")

        // 3. Tapping it returns to the bottom and hides it.
        goToEnd.tap()
        XCTAssertTrue(
            goToEnd.waitForNonExistence(timeout: 5),
            "Go to End stayed visible after tapping it")
        XCTAssertTrue(
            waitUntilVisible(lastMessage, in: transcript, timeout: 5),
            "last transcript message is not visible after Go to End")

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
        let triggerFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-hooks-row-\(UUID().uuidString).trigger")
        try? FileManager.default.removeItem(at: triggerFile)
        defer { try? FileManager.default.removeItem(at: triggerFile) }

        let app = launchDemoApp(extraArguments: [Fixture.hooksRowTriggerFileArgumentPrefix + triggerFile.path])
        let opened = openLongConversation(in: app)
        let lastMessage = opened.lastMessage
        let goToEnd = opened.goToEnd
        let transcript = opened.transcript

        // 1. Settle at the bottom while the hooks row is held back by the
        //    trigger file. The baseline gap is taken only once two consecutive
        //    polls agree, so a sample during a still-animating follow (or its
        //    landing retry) cannot become a stale baseline.
        XCTAssertTrue(
            waitUntilVisible(lastMessage, in: transcript, timeout: 10),
            "transcript did not settle on the last message after opening")
        let hooksRow = app.staticTexts[Fixture.hooksRowLabel].firstMatch
        XCTAssertFalse(
            hooksRow.exists,
            "hooks row was already present when the transcript settled; the fixture trigger file did not hold it back")
        let bottomBeforeRow = transcript.frame.maxY
        guard let gapBeforeRow = waitUntilSteady(timeout: 5, tolerance: Fixture.rePinTolerance, {
            transcript.frame.maxY - lastMessage.frame.maxY
        }) else {
            return XCTFail("transcript kept moving after the last message became visible; no steady baseline gap")
        }
        XCTAssertFalse(
            hooksRow.exists,
            "hooks row was already present when the baseline gap was recorded; the fixture trigger file did not hold it back")

        // 2. Release the hooks row; it appears and shrinks the transcript from below.
        try Data().write(to: triggerFile)
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
        //    (new) bottom edge as before the row, no Go to End over a window
        //    that outlasts the re-pin and its settle delays, and the last
        //    message still on screen.
        var gapAfterRow = transcript.frame.maxY - lastMessage.frame.maxY
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                gapAfterRow = transcript.frame.maxY - lastMessage.frame.maxY
                return abs(gapAfterRow - gapBeforeRow) <= Fixture.rePinTolerance
            },
            "transcript did not re-pin to the bottom after the hooks row appeared: "
                + "last message sat \(gapAfterRow) pt above the bottom edge, \(gapBeforeRow) pt before the row")
        XCTAssertFalse(
            goToEnd.waitForExistence(timeout: 3),
            "Go to End appeared after the hooks row shrank the transcript")
        XCTAssertTrue(
            waitUntilVisible(lastMessage, in: transcript, timeout: 5),
            "last transcript message is not visible after the hooks row appeared")
    }

    /// Tapping a suggested prompt under the last assistant message appends
    /// the optimistic user row and the thinking indicator while the prompt
    /// rows disappear (the last message is now the user's). The transcript
    /// was resting at the bottom, so it must follow: once layout settles Go
    /// to End must not be shown and the sent row and the thinking indicator
    /// must rest inside the transcript (intent-hq/ios#281, symptom 1).
    @MainActor
    func testTappingSuggestedPromptKeepsTranscriptAtBottomAndGoToEndHidden() throws {
        let app = launchDemoApp()
        let opened = openLongConversation(in: app)
        let transcript = opened.transcript
        let goToEnd = opened.goToEnd

        // 1. Settled at the bottom with the prompt rows on screen.
        assertRestsAtBottom(
            lastRow: opened.lastMessage, named: "last assistant paragraph",
            in: opened, context: "before tapping the suggested prompt")
        let prompt = app.buttons[Fixture.firstSuggestedPromptIdentifier].firstMatch
        XCTAssertTrue(
            prompt.waitForExistence(timeout: 5),
            "first suggested prompt button not found under the last message")
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
        XCTAssertTrue(
            thinkingIndicator.waitForExistence(timeout: 5),
            "thinking indicator did not appear after tapping the suggested prompt — "
                + restingState(of: sentRow, named: "sent prompt row", in: opened))

        // 3. Still pinned: the sent row on screen, the indicator (last row)
        //    inside the transcript, no Go to End over the settle window.
        XCTAssertTrue(
            waitUntilVisible(sentRow, in: transcript, timeout: 10),
            "sent prompt row never came on screen after tapping the suggested prompt — "
                + restingState(of: sentRow, named: "sent prompt row", in: opened))
        assertRestsAtBottom(
            lastRow: thinkingIndicator, named: "thinking indicator",
            in: opened, context: "after tapping the suggested prompt")
        XCTAssertTrue(
            waitUntilVisible(sentRow, in: transcript, timeout: 2),
            "sent prompt row left the screen after the transcript settled — "
                + restingState(of: sentRow, named: "sent prompt row", in: opened))
        XCTAssertFalse(goToEnd.exists, "Go to End is visible after tapping the suggested prompt")
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
    /// must show the last message inside the transcript at the very first
    /// settled sample, over a non-empty visible band, and must have reached
    /// the very end: the prompt rows under the last message — the
    /// LazyVStack's final content rows — are realized and on screen too. A
    /// transcript that rests on the last message with those rows never laid
    /// out is short of the end with Go to End hidden (the state the
    /// coordinator-shaped fixture reproduces on CI; intent-hq/ios#304).
    /// Unlike `assertRestsAtBottom`, the checks run at the first sample where
    /// the content holds still rather than after a grace period in which a
    /// late re-pin could mask the symptom, and Go to End must stay absent
    /// over the quiet window that follows. The symptom is intermittent (on
    /// CI it showed at cold entry in one run and only after a send in the
    /// next), so the cold entry is repeated — a fresh launch each cycle, as
    /// a return through the workspace list would mount the cached transcript.
    @MainActor
    func testFirstOpenOfLongConversationShowsLastMessageWithNoBlankBand() throws {
        for cycle in 1...Fixture.entryCycles {
            let context = "cold entry \(cycle)/\(Fixture.entryCycles)"
            let app = launchDemoApp()
            let opened = enterLongConversation(in: app, context: context)
            let lastMessage = opened.lastMessage
            let goToEnd = opened.goToEnd
            let transcript = opened.transcript
            let endRow = app.buttons[Fixture.firstSuggestedPromptIdentifier].firstMatch

            // 1. First settled sample: the last row exists and its frame holds
            //    still across two consecutive polls. An unrealized last row (the
            //    viewport resting past the end) never satisfies this.
            let firstSettledSample = waitUntilSteady(timeout: 10, tolerance: Fixture.rePinTolerance) {
                lastMessage.exists ? lastMessage.frame.maxY : .nan
            }
            let visibleBand = rows(intersecting: transcript)
            XCTAssertFalse(
                visibleBand.isEmpty,
                "\(context): the transcript's visible band is empty — no message row intersects the transcript frame — "
                    + restingState(of: lastMessage, named: "last assistant paragraph", in: opened))
            XCTAssertNotNil(
                firstSettledSample,
                "\(context): the last message never held still inside the transcript within 10 s "
                    + "(\(visibleBand.count) row(s) in the visible band) — "
                    + restingState(of: lastMessage, named: "last assistant paragraph", in: opened))
            XCTAssertTrue(
                isInside(lastMessage, transcript),
                "\(context): at the first settled sample the last message is not inside the transcript — "
                    + restingState(of: lastMessage, named: "last assistant paragraph", in: opened))
            XCTAssertTrue(
                isInside(endRow, transcript),
                "\(context): at the first settled sample the transcript is short of the end — the prompt rows under "
                    + "the last message are not on screen — "
                    + restingState(of: endRow, named: "first suggested prompt", in: opened))

            // 2. Go to End never appears over the quiet window, and the last
            //    message and the end row are still on screen at the end of it.
            XCTAssertFalse(
                goToEnd.waitForExistence(timeout: Fixture.quietWindow),
                "\(context): Go to End appeared after the transcript settled — "
                    + restingState(of: lastMessage, named: "last assistant paragraph", in: opened))
            XCTAssertTrue(
                waitUntilVisible(lastMessage, in: transcript, timeout: Fixture.settleWindow),
                "\(context): the last message left the screen after the quiet window — "
                    + restingState(of: lastMessage, named: "last assistant paragraph", in: opened))
            XCTAssertTrue(
                isInside(endRow, transcript),
                "\(context): the transcript is short of the end after the quiet window — "
                    + restingState(of: endRow, named: "first suggested prompt", in: opened))
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
        let endRow = app.buttons[Fixture.firstSuggestedPromptIdentifier].firstMatch
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

        // 2. One tap, then no further interaction: the last message must
        //    come on screen and the button must go and stay gone.
        goToEnd.tap()
        XCTAssertTrue(
            waitUntilVisible(lastMessage, in: transcript, timeout: 10),
            "one tap on Go to End from the top (after \(swipes) swipes) did not bring the last message on screen — "
                + restingState(of: lastMessage, named: "last assistant paragraph", in: opened))
        XCTAssertTrue(
            goToEnd.waitForNonExistence(timeout: 5),
            "Go to End stayed visible after one tap from the top — "
                + restingState(of: lastMessage, named: "last assistant paragraph", in: opened))
        XCTAssertFalse(
            goToEnd.waitForExistence(timeout: Fixture.quietWindow),
            "Go to End reappeared after one tap from the top; a second tap would be needed — "
                + restingState(of: lastMessage, named: "last assistant paragraph", in: opened))
        XCTAssertTrue(
            isInside(lastMessage, transcript),
            "the last message is not inside the transcript after one tap from the top — "
                + restingState(of: lastMessage, named: "last assistant paragraph", in: opened))
        XCTAssertTrue(
            isInside(endRow, transcript),
            "one tap from the top stopped short of the end: the prompt rows under the last message are not "
                + "on screen — " + restingState(of: endRow, named: "first suggested prompt", in: opened))
    }

    // MARK: - Helpers

    @MainActor
    private func launchDemoApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data"] + extraArguments
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
    /// frame: empty when the viewport rests over a blank band.
    @MainActor
    private func rows(intersecting transcript: XCUIElement) -> [XCUIElement] {
        let transcriptFrame = transcript.frame
        return transcript.staticTexts.allElementsBoundByIndex.filter { row in
            let frame = row.frame
            return !frame.isEmpty && frame.intersects(transcriptFrame)
        }
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
    /// row: the row comes on screen, its frame stops moving, and then — over
    /// `Fixture.settleWindow`, which outlasts the follow's completion timer
    /// and its retries — it stays inside the transcript's frame while Go to
    /// End never appears. Every failure message carries `restingState`.
    @MainActor
    private func assertRestsAtBottom(
        lastRow: XCUIElement, named rowName: String, in opened: OpenConversation, context: String
    ) {
        let transcript = opened.transcript
        let goToEnd = opened.goToEnd
        XCTAssertTrue(
            waitUntilVisible(lastRow, in: transcript, timeout: 10),
            "\(context): transcript did not settle on the \(rowName) — "
                + restingState(of: lastRow, named: rowName, in: opened))
        XCTAssertNotNil(
            waitUntilSteady(timeout: 5, tolerance: Fixture.rePinTolerance, { lastRow.frame.maxY }),
            "\(context): transcript kept moving after the \(rowName) became visible — "
                + restingState(of: lastRow, named: rowName, in: opened))
        let broke = waitUntil(timeout: Fixture.settleWindow) {
            goToEnd.exists || !isInside(lastRow, transcript)
        }
        XCTAssertFalse(
            broke,
            "\(context): transcript is not resting at the bottom after settling — "
                + restingState(of: lastRow, named: rowName, in: opened))
    }

    /// True when the element's whole frame lies inside the container's frame
    /// (within `rePinTolerance` for rounding).
    @MainActor
    private func isInside(_ element: XCUIElement, _ container: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        return !frame.isEmpty
            && container.frame.insetBy(dx: 0, dy: -Fixture.rePinTolerance).contains(frame)
    }

    /// Diagnostic sentence for failure messages: Go to End presence and
    /// where `row`'s frame lies relative to the transcript's frame — ABOVE it
    /// means the viewport rests past the end (blank band), BELOW it means the
    /// viewport rests short of the end.
    @MainActor
    private func restingState(of row: XCUIElement, named rowName: String, in opened: OpenConversation) -> String {
        let transcriptFrame = opened.transcript.frame
        let goToEndState = opened.goToEnd.exists ? "Go to End PRESENT" : "Go to End absent"
        guard row.exists else {
            return "\(goToEndState); \(rowName) is not in the accessibility hierarchy (unrealized / off screen); "
                + "transcript frame \(transcriptFrame)"
        }
        let rowFrame = row.frame
        let position: String
        if rowFrame.maxY <= transcriptFrame.minY {
            position = "ABOVE the transcript (viewport rests past the end)"
        } else if rowFrame.minY >= transcriptFrame.maxY {
            position = "BELOW the transcript (viewport rests short of the end)"
        } else if transcriptFrame.insetBy(dx: 0, dy: -Fixture.rePinTolerance).contains(rowFrame) {
            position = "inside the transcript"
        } else if rowFrame.minY < transcriptFrame.minY {
            position = "clipped by the transcript's top edge (partly past the end)"
        } else {
            position = "clipped by the transcript's bottom edge (partly short of the end)"
        }
        return "\(goToEndState); \(rowName) frame \(rowFrame) is \(position); transcript frame \(transcriptFrame)"
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
        guard element.exists else { return false }
        let frame = element.frame
        return !frame.isEmpty && container.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Polls `condition` every 0.25 s until it holds or `timeout` elapses.
    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return false
    }

    /// Samples `value` every 0.25 s and returns it once two consecutive
    /// samples agree within `tolerance`; nil if that never happens before
    /// `timeout` elapses.
    @MainActor
    private func waitUntilSteady(
        timeout: TimeInterval, tolerance: CGFloat, _ value: () -> CGFloat
    ) -> CGFloat? {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = value()
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let current = value()
            if abs(current - previous) <= tolerance { return current }
            previous = current
        } while Date() < deadline
        return nil
    }
}
