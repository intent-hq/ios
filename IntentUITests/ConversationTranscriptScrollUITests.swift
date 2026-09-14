import XCTest

/// Guards the "Go to End" affordance of the conversation transcript against
/// `--demo-data` fixtures: hidden while resting at the bottom, shown once the
/// user scrolls up, hidden again after tapping it or scrolling back down, and
/// still hidden — with the last message still on screen — when a footer row
/// (the background-hooks chip row) appears under the settled transcript.
///
/// Runs under the `Intent` scheme (`scripts/xcodebuild.sh test-ios`, CI).
/// The transcript is the 32-message `DemoFixtures.longConversationMessages`
/// served for the "Deflake payment integration tests" workspace, whose single
/// agent opens straight into the transcript from the workspace row. That
/// workspace's `hook.list` fixture waits on `DemoFixtures.longConversationHookListGate`
/// — a delay by default, or a trigger file the test creates — so its hooks
/// row lands only after the transcript has been observed settled.
nonisolated final class ConversationTranscriptScrollUITests: XCTestCase {

    private enum Fixture {
        static let workspaceTitle = "Deflake payment integration tests"
        // Distinctive substrings of DemoFixtures.longConversationFirstSentence
        // / longConversationLastSentence (the UI test target cannot import
        // the app module, so match on text the way AppStoreScreenshotTests does).
        static let firstMessageFragment = "Start of the flake investigation"
        static let lastMessageFragment = "End of the flake investigation"
        static let goToEndIdentifier = "transcript.goToEnd"
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

    // MARK: - Helpers

    @MainActor
    private func launchDemoApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data"] + extraArguments
        app.launch()
        return app
    }

    /// Taps the long-conversation workspace row and waits for its transcript,
    /// Go to End button handle and scroll view.
    @MainActor
    private func openLongConversation(in app: XCUIApplication) -> OpenConversation {
        let workspaceRow = app.staticTexts[Fixture.workspaceTitle].firstMatch
        if !workspaceRow.waitForExistence(timeout: 30) {
            // Same fallback as AppStoreScreenshotTests: a collapsed iPad
            // sidebar hides the workspace list behind the first nav button.
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(workspaceRow.waitForExistence(timeout: 15))
        }
        workspaceRow.tap()

        let lastMessage = message(in: app, containing: Fixture.lastMessageFragment)
        XCTAssertTrue(lastMessage.waitForExistence(timeout: 15), "last transcript message never appeared")
        let goToEnd = app.buttons[Fixture.goToEndIdentifier].firstMatch
        let transcript = app.scrollViews[Fixture.transcriptIdentifier].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 5), "transcript scroll view not found")
        return OpenConversation(lastMessage: lastMessage, goToEnd: goToEnd, transcript: transcript)
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
        waitUntil(timeout: timeout) {
            guard element.exists else { return false }
            let frame = element.frame
            return !frame.isEmpty && container.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
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
