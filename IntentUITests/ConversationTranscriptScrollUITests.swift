import XCTest

nonisolated final class ConversationTranscriptScrollUITests: XCTestCase {
    // swiftlint:disable test_case_accessibility
    let hooksRowTriggerFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcript-hooks-row-\(UUID().uuidString).trigger")

    let blockHydrationTriggerFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcript-block-hydration-\(UUID().uuidString).trigger")

    let endDerealizationTriggerFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcript-end-derealization-\(UUID().uuidString).trigger")

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
        nonisolated(unsafe) let test = self
        MainActor.assumeIsolated { test.attachPendingRecoveryEvidence() }
        try? FileManager.default.removeItem(at: hooksRowTriggerFile)
        try? FileManager.default.removeItem(at: blockHydrationTriggerFile)
        try? FileManager.default.removeItem(at: endDerealizationTriggerFile)
        try super.tearDownWithError()
    }
}

extension ConversationTranscriptScrollUITests {
    @MainActor
    // swiftlint:disable:next function_body_length
    func testTappingSuggestedPromptKeepsTranscriptAtBottomAndGoToEndHidden() {
        let app = launchDemoApp(hooksRowTriggerFile: hooksRowTriggerFile)
        let opened = openLongConversation(in: app)
        let transcript = opened.transcript

        assertRestsAtBottom(
            lastRow: opened.lastMessage,
            named: "last assistant paragraph",
            endRow: EndRow.lastSuggestedPrompt(in: app),
            in: opened,
            context: "before tapping the suggested prompt",
            allowPreservedEntry: true
        )
        let prompt = app.buttons[Fixture.firstSuggestedPromptIdentifier].firstMatch
        XCTAssertTrue(
            waitUntilVisible(prompt, in: transcript, timeout: 5),
            "first suggested prompt is not on screen while the transcript rests at the bottom — "
                + restingState(of: prompt, named: "prompt button", in: opened)
        )

        XCTAssertEqual(prompt.label, Fixture.firstSuggestedPromptLabel)
        add(transcriptScreenshot(in: app, named: "Workspace-Suggested-Prompts"))

        let beforeSend = forcedFollowRequestCount(in: opened)
        prompt.tap()
        XCTAssertTrue(
            prompt.waitForNonExistence(timeout: 5),
            "suggested prompt rows stayed in the transcript after tapping one"
        )
        let sentRow = message(in: app, containing: Fixture.firstSuggestedPromptLabel)
        let thinkingIndicator = EndRow.thinkingIndicator(in: app)

        guard waitUntilSettled(
            on: thinkingIndicator.element,
            named: thinkingIndicator.name,
            in: opened,
            context: "after tapping the suggested prompt",
            forcedFollowAfter: beforeSend,
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
                context: "entry cycle \(cycle)",
                allowPreservedEntry: true
            )
            leaveConversation(in: app)
        }
    }
}

extension ConversationTranscriptScrollUITests {
    @MainActor
    // swiftlint:disable:next function_body_length
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
            context: "before scrolling to the top",
            allowPreservedEntry: true
        )

        let firstMessage = message(in: app, containing: Fixture.firstMessageFragment)
        var swipes = 0
        while swipes < Fixture.maxSwipesToTop, !firstMessage.exists || !isVisible(firstMessage, in: transcript) {
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

        let beforeGoToEnd = forcedFollowRequestCount(in: opened)
        goToEnd.tap()
        let context = "after one tap on Go to End from the top (after \(swipes) swipes)"
        guard waitUntilSettled(
            on: lastMessage,
            named: "last assistant paragraph",
            in: opened,
            context: context,
            forcedFollowAfter: beforeGoToEnd,
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
        addTeardownBlock { @MainActor [self] () async in finishStartup(app) }
        let opened = enterLongConversation(in: app, context: "ready metadata", waitForTranscript: false)
        XCTAssertTrue(startupControl(app).waitForExistence(timeout: Fixture.settleTimeout))
        XCTAssertTrue(waitUntil(timeout: Fixture.settleTimeout) { self.startupReport(app).contains("metadata=ready") })
        XCTAssertFalse(opened.transcript.exists, "the chat snapshot is still held")
        try Data().write(to: startupSnapshotGate)
        let divider = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "New messages")).firstMatch
        addTeardownBlock { @MainActor [self] () async in
            attachStartupViewport(app, opened: opened, report: startupReport(app), row: divider, context: "ready entry divider")
        }
        XCTAssertTrue(waitUntil(timeout: Fixture.settleTimeout) {
            guard self.startupReport(app).contains("positioned=true"), let rect = frame(of: divider) else { return false }
            return isInside(rect, opened.transcript)
        })
        assertStartupDividerGeometry(app, opened: opened)
        let row = try startupVisibleRow(opened)
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
        guard waitUntilStartupGestureEnded(in: app) else { return }
        let row = try startupVisibleRow(opened)
        XCTAssertTrue(startupReport(app).contains("metadata=pending"))
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "New messages")).firstMatch.exists)
        try assertStartupViewportStays(app, opened: opened, row: row) { try Data().write(to: startupMetadataGate) }
        XCTAssertFalse(isInside(last, opened.transcript), "late entry work must not take the gesture back to the bottom")
    }

    @MainActor
    func testRetainedConversationReappearsWithoutRepeatingEntryPositioning() throws {
        let app = try launchStartupConversation()
        addTeardownBlock { @MainActor [self] () async in finishStartup(app) }
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
        attachStartupViewport(app, opened: opened, report: startupReport(app), row: row, context: "before retained cover")
        addTeardownBlock { @MainActor [self] () async in
            attachStartupViewport(app, opened: opened, report: startupReport(app), row: row, context: "after retained return")
        }
        startupControl(app).tap()
        let back = app.buttons["demo.conversation.return"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: Fixture.settleTimeout))
        back.tap()
        XCTAssertTrue(waitUntil(timeout: Fixture.settleTimeout) {
            self.startupReport(app).contains("metadata=pending") && isInside(row, opened.transcript)
        })
        XCTAssertEqual(startupReport(app).components(separatedBy: "consumer=").last, consumer, "the same view model must reappear")
        attachStartupViewport(app, opened: opened, report: startupReport(app), row: row, context: "retained return before geometry assertion")
        XCTAssertEqual((frame(of: row)?.minY ?? .nan) - opened.transcript.frame.minY, oldY, accuracy: Fixture.rePinTolerance)
        try assertStartupViewportStays(app, opened: opened, row: row) { try Data().write(to: startupMetadataGate) }
    }

    private var startupMetadataGate: URL { hooksRowTriggerFile.appendingPathExtension("metadata") }
    var startupSnapshotGate: URL { hooksRowTriggerFile.appendingPathExtension("snapshot") }

    @MainActor
    func launchStartupConversation(metadataReady: Bool = false, holdSnapshot: Bool = false, appearance: String? = nil) throws -> XCUIApplication {
        try? FileManager.default.removeItem(at: startupMetadataGate)
        try? FileManager.default.removeItem(at: startupSnapshotGate)
        if metadataReady { try Data().write(to: startupMetadataGate) }
        var arguments = ["--demo-startup-transcript", "--demo-agent-detail-trigger-file=" + startupMetadataGate.path]
        if holdSnapshot { arguments.append("--demo-chat-snapshot-trigger-file=" + startupSnapshotGate.path) }
        return launchDemoApp(hooksRowTriggerFile: hooksRowTriggerFile, extraArguments: arguments + (appearance.map { ["-appThemePreference", $0] } ?? []))
    }

    @MainActor
    func finishStartup(_ app: XCUIApplication) {
        app.terminate()
        try? FileManager.default.removeItem(at: startupMetadataGate)
        try? FileManager.default.removeItem(at: startupSnapshotGate)
    }

    @MainActor
    func startupControl(_ app: XCUIApplication) -> XCUIElement { app.buttons["demo.conversation.cover"].firstMatch }

    @MainActor
    func startupReport(_ app: XCUIApplication) -> String { startupControl(app).value as? String ?? "" }

    @MainActor
    private func assertStartupViewportStays(
        _ app: XCUIApplication, opened: OpenConversation, row: XCUIElement, release: () throws -> Void
    ) throws {
        let expectedLabel = row.label
        let baseline = try XCTUnwrap(waitUntilSteady(timeout: Fixture.settleTimeout, tolerance: Fixture.rePinTolerance) {
            (frame(of: row)?.minY ?? .nan) - opened.transcript.frame.minY
        })
        XCTAssertEqual(row.label, expectedLabel, "the baseline must measure the selected row")
        XCTAssertTrue(isInside(row, opened.transcript), "the baseline must measure a fully visible row")
        try release()
        var moved = false
        let ready = waitUntil(timeout: Fixture.settleTimeout) {
            moved = moved || self.startupRowMoved(row, label: expectedLabel, opened: opened, baseline: baseline)
            return self.startupReport(app).contains("positioned=true") && self.startupReport(app).contains("entry=ready")
        }
        XCTAssertTrue(ready, "entry never became ready: \(startupReport(app))")
        XCTAssertTrue(startupReport(app).contains("anchor=startup-row-25"))
        let movedLater = waitUntil(timeout: Fixture.quietWindow) { self.startupRowMoved(row, label: expectedLabel, opened: opened, baseline: baseline) }
        let attachment = XCTAttachment(string: "rowBefore=\(expectedLabel) rowAfter=\(row.label)"
            + " before=\(baseline) after=\((frame(of: row)?.minY ?? .nan) - opened.transcript.frame.minY)"
            + " \(startupReport(app)) \(followReport(in: opened))")
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(row.label, expectedLabel, "metadata must not retarget the measured row")
        XCTAssertFalse(moved || movedLater, "metadata or deferred entry work moved the visible row")
    }

    @MainActor
    private func startupRowMoved(_ row: XCUIElement, label: String, opened: OpenConversation, baseline: CGFloat) -> Bool {
        guard let snapshot = try? row.snapshot(), snapshot.label == label, !snapshot.frame.isEmpty,
              isInside(snapshot.frame, opened.transcript) else { return true }
        return abs(snapshot.frame.minY - opened.transcript.frame.minY - baseline) > Fixture.rePinTolerance
    }

    @MainActor
    private func revealStartupDivider(_ app: XCUIApplication, opened: OpenConversation) {
        let divider = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "New messages")).firstMatch
        let maximumViewportSteps = 30
        for _ in 0..<maximumViewportSteps {
            if isInside(divider, opened.transcript) { return }
            let visible = rows(intersecting: opened.transcript).compactMap { row -> Int? in
                guard row.label.hasPrefix("Startup row ") else { return nil }
                return Int(row.label.dropFirst("Startup row ".count).prefix { $0.isNumber })
            }
            let markerRow = 25
            let towardEarlier = (visible.min() ?? markerRow) > markerRow
            let startY = towardEarlier ? 0.35 : 0.65
            let endY = towardEarlier ? 0.65 : 0.35
            let start = opened.transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
            let end = opened.transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
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

extension ConversationTranscriptScrollUITests {
    func testPostActionSettlementRequiresAFollowThatActuallyStarted() {
        let preserved = "lastForcedFollow=pending entry=preserved metadataReady=true forcedRequested=false followActive=false phase=idle"
        XCTAssertFalse(viewportHasReportedSettlement(preserved), "post-action checks must require a terminal forced follow")
        let completed = "lastForcedFollow=landed forcedRequested=true forcedRequests=2 followActive=false phase=idle"
        XCTAssertFalse(viewportHasReportedSettlement(completed, forcedFollowAfter: 2), "an old terminal report is insufficient")
        XCTAssertTrue(viewportHasReportedSettlement(completed, forcedFollowAfter: 1))
        XCTAssertFalse(viewportHasReportedSettlement(completed.replacingOccurrences(of: "landed", with: "pending"), forcedFollowAfter: 1))
        let recovered = "lastForcedFollow=pending endRecovery=recovered corrections=1 episodes=2 endRealized=true followActive=false phase=idle"
        XCTAssertTrue(viewportHasReportedSettlement(recovered, recoveryAfter: 1))
        XCTAssertFalse(viewportHasReportedSettlement(recovered.replacingOccurrences(of: "followActive=false", with: "followActive=true"), recoveryAfter: 1))
        XCTAssertFalse(viewportHasReportedSettlement(recovered, recoveryAfter: 2))
        XCTAssertFalse(viewportHasReportedSettlement(recovered.replacingOccurrences(of: "corrections=1", with: "corrections=0"), recoveryAfter: 1))
        XCTAssertFalse(viewportHasReportedSettlement(recovered.replacingOccurrences(of: "endRealized=true", with: "endRealized=false"), recoveryAfter: 1))
        XCTAssertFalse(viewportHasReportedSettlement(recovered.replacingOccurrences(of: "endRecovery=recovered", with: "endRecovery=recovering"), recoveryAfter: 1))
    }

    func testInitialSettlementDoesNotMistakeAnActiveFollowForPreservedEntry() {
        let preserved = "lastForcedFollow=pending entry=preserved metadataReady=true forcedRequested=false followActive=false phase=idle"
        XCTAssertTrue(viewportHasReportedSettlement(preserved, allowPreservedEntry: true))
        XCTAssertFalse(viewportHasReportedSettlement(preserved + " endRecovery=recovering corrections=0 episodes=1 endRealized=false", allowPreservedEntry: true))
        for (ready, notReady) in [
            ("metadataReady=true", "metadataReady=false"), ("entry=preserved", "entry=pending"),
            ("forcedRequested=false", "forcedRequested=true"), ("followActive=false", "followActive=true"),
            ("phase=idle", "phase=gesture")
        ] {
            XCTAssertFalse(viewportHasReportedSettlement(preserved.replacingOccurrences(of: ready, with: notReady), allowPreservedEntry: true))
        }
        XCTAssertTrue(viewportHasReportedSettlement("lastForcedFollow=landed forcedRequested=true followActive=false phase=idle"))
        XCTAssertFalse(viewportHasReportedSettlement("lastForcedFollow=landed forcedRequested=true followActive=true phase=idle"))
    }
}
