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

        XCTAssertEqual(prompt.label, Fixture.firstSuggestedPromptLabel)

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

extension ConversationTranscriptScrollUITests {
    @MainActor
    func testReadyMetadataPositionsLongUnreadEntryAtTheAuthoritativeDivider() throws {
        let app = try launchStartupConversation(metadataReady: true, holdSnapshot: true)
        defer { finishStartup(app) }
        let opened = enterLongConversation(in: app, context: "ready metadata", waitForTranscript: false)
        XCTAssertTrue(startupControl(app).waitForExistence(timeout: Fixture.settleTimeout))
        XCTAssertTrue(waitUntil(timeout: Fixture.settleTimeout) { self.startupReport(app).contains("metadata=ready") })
        XCTAssertFalse(opened.transcript.exists, "the chat snapshot is still held")
        try Data().write(to: startupSnapshotGate)
        let divider = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "New messages")).firstMatch
        XCTAssertTrue(waitUntil(timeout: Fixture.settleTimeout) {
            guard self.startupReport(app).contains("positioned=true"), let rect = frame(of: divider) else { return false }
            return isInside(rect, opened.transcript)
        })
        assertStartupDividerGeometry(app, opened: opened)
        let row = message(in: app, containing: "Startup row 26.")
        try assertStartupViewportStays(app, opened: opened, row: row) {}
    }

    @MainActor
    func testLateMetadataAddsTheCorrectDividerWithoutMovingVisibleRows() throws {
        let app = try launchStartupConversation()
        defer { finishStartup(app) }
        let opened = enterLongConversation(in: app, context: "delayed marker")
        let last = message(in: app, containing: "Startup row 49.")
        XCTAssertTrue(waitUntil(timeout: Fixture.settleTimeout) { isInside(last, opened.transcript) })
        XCTAssertTrue(startupReport(app).contains("metadata=pending"))
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "New messages")).firstMatch.exists)
        try assertStartupViewportStays(app, opened: opened, row: last) { try Data().write(to: startupMetadataGate) }
        revealStartupDivider(app, opened: opened)
        assertStartupDividerGeometry(app, opened: opened)
    }

    @MainActor
    func testGestureBeforeMetadataKeepsItsViewportAfterTheMarkerArrives() throws {
        let app = try launchStartupConversation()
        defer { finishStartup(app) }
        let opened = enterLongConversation(in: app, context: "gesture before marker")
        let last = message(in: app, containing: "Startup row 49.")
        XCTAssertTrue(waitUntil(timeout: Fixture.settleTimeout) { isInside(last, opened.transcript) })
        opened.transcript.swipeDown()
        let row = try startupVisibleRow(opened)
        XCTAssertTrue(startupReport(app).contains("metadata=pending"))
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "New messages")).firstMatch.exists)
        try assertStartupViewportStays(app, opened: opened, row: row) { try Data().write(to: startupMetadataGate) }
        XCTAssertFalse(isInside(last, opened.transcript), "late entry work must not take the gesture back to the bottom")
    }

    @MainActor
    func testRetainedConversationReappearsWithoutRepeatingEntryPositioning() throws {
        let app = try launchStartupConversation()
        defer { finishStartup(app) }
        let opened = enterLongConversation(in: app, context: "retained binding")
        let last = message(in: app, containing: "Startup row 49.")
        XCTAssertTrue(waitUntil(timeout: Fixture.settleTimeout) { isInside(last, opened.transcript) })
        try assertStartupViewportStays(app, opened: opened, row: last) { try Data().write(to: startupMetadataGate) }
        opened.transcript.swipeDown()
        let row = try startupVisibleRow(opened)
        let consumer = try XCTUnwrap(startupReport(app).components(separatedBy: "consumer=").last)
        let oldY = try XCTUnwrap(waitUntilSteady(timeout: Fixture.settleTimeout, tolerance: Fixture.rePinTolerance) {
            (frame(of: row)?.minY ?? .nan) - opened.transcript.frame.minY
        })
        try FileManager.default.removeItem(at: startupMetadataGate)
        startupControl(app).tap()
        let back = app.buttons["demo.conversation.return"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: Fixture.settleTimeout))
        back.tap()
        XCTAssertTrue(waitUntil(timeout: Fixture.settleTimeout) {
            self.startupReport(app).contains("metadata=pending") && isInside(row, opened.transcript)
        })
        XCTAssertEqual(startupReport(app).components(separatedBy: "consumer=").last, consumer, "the same view model must reappear")
        XCTAssertEqual((frame(of: row)?.minY ?? .nan) - opened.transcript.frame.minY, oldY, accuracy: Fixture.rePinTolerance)
        try assertStartupViewportStays(app, opened: opened, row: row) { try Data().write(to: startupMetadataGate) }
    }

    private var startupMetadataGate: URL { hooksRowTriggerFile.appendingPathExtension("metadata") }
    private var startupSnapshotGate: URL { hooksRowTriggerFile.appendingPathExtension("snapshot") }

    @MainActor
    private func launchStartupConversation(metadataReady: Bool = false, holdSnapshot: Bool = false) throws -> XCUIApplication {
        try? FileManager.default.removeItem(at: startupMetadataGate)
        try? FileManager.default.removeItem(at: startupSnapshotGate)
        if metadataReady { try Data().write(to: startupMetadataGate) }
        var arguments = ["--demo-startup-transcript", "--demo-agent-detail-trigger-file=" + startupMetadataGate.path]
        if holdSnapshot { arguments.append("--demo-chat-snapshot-trigger-file=" + startupSnapshotGate.path) }
        return launchDemoApp(hooksRowTriggerFile: hooksRowTriggerFile, extraArguments: arguments)
    }

    @MainActor
    private func finishStartup(_ app: XCUIApplication) {
        app.terminate()
        try? FileManager.default.removeItem(at: startupMetadataGate)
        try? FileManager.default.removeItem(at: startupSnapshotGate)
    }

    @MainActor
    private func startupControl(_ app: XCUIApplication) -> XCUIElement { app.buttons["demo.conversation.cover"].firstMatch }

    @MainActor
    private func startupReport(_ app: XCUIApplication) -> String { startupControl(app).value as? String ?? "" }

    @MainActor
    private func startupVisibleRow(_ opened: OpenConversation) throws -> XCUIElement {
        var row: XCUIElement?
        XCTAssertTrue(waitUntil(timeout: Fixture.settleTimeout) {
            row = rows(intersecting: opened.transcript).first { $0.label.hasPrefix("Startup row") && isInside($0, opened.transcript) }
            return row != nil
        })
        return try XCTUnwrap(row)
    }

    @MainActor
    private func assertStartupViewportStays(
        _ app: XCUIApplication, opened: OpenConversation, row: XCUIElement, release: () throws -> Void
    ) throws {
        let baseline = try XCTUnwrap(waitUntilSteady(timeout: Fixture.settleTimeout, tolerance: Fixture.rePinTolerance) {
            (frame(of: row)?.minY ?? .nan) - opened.transcript.frame.minY
        })
        try release()
        var moved = false
        let ready = waitUntil(timeout: Fixture.settleTimeout) {
            moved = moved || self.startupRowMoved(row, opened: opened, baseline: baseline)
            return self.startupReport(app).contains("positioned=true") && self.startupReport(app).contains("entry=ready")
        }
        XCTAssertTrue(ready, "entry never became ready: \(startupReport(app))")
        XCTAssertTrue(startupReport(app).contains("anchor=startup-row-25"))
        let movedLater = waitUntil(timeout: Fixture.quietWindow) { self.startupRowMoved(row, opened: opened, baseline: baseline) }
        let attachment = XCTAttachment(string: "row=\(row.label) before=\(baseline) after=\((frame(of: row)?.minY ?? .nan) - opened.transcript.frame.minY) \(startupReport(app))")
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertFalse(moved || movedLater, "metadata or deferred entry work moved the visible row")
    }

    @MainActor
    private func startupRowMoved(_ row: XCUIElement, opened: OpenConversation, baseline: CGFloat) -> Bool {
        guard let rect = frame(of: row), isInside(rect, opened.transcript) else { return true }
        return abs(rect.minY - opened.transcript.frame.minY - baseline) > Fixture.rePinTolerance
    }

    @MainActor
    private func revealStartupDivider(_ app: XCUIApplication, opened: OpenConversation) {
        let divider = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "New messages")).firstMatch
        for _ in 0..<Fixture.maxSwipesToTop {
            if isInside(divider, opened.transcript) { return }
            opened.transcript.swipeDown()
        }
        XCTFail("the authoritative unread divider was never visible")
    }

    @MainActor
    private func assertStartupDividerGeometry(_ app: XCUIApplication, opened: OpenConversation) {
        let divider = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "New messages")).firstMatch
        XCTAssertTrue(isInside(divider, opened.transcript))
        if let before = frame(of: message(in: app, containing: "Startup row 25.")),
           let after = frame(of: message(in: app, containing: "Startup row 26.")),
           let rect = frame(of: divider) {
            XCTAssertLessThanOrEqual(before.maxY, rect.minY)
            XCTAssertLessThanOrEqual(rect.maxY, after.minY)
        } else { XCTFail("unread divider neighbors are not realized") }
        XCTAssertTrue(startupReport(app).contains("anchor=startup-row-25"))
    }
}
