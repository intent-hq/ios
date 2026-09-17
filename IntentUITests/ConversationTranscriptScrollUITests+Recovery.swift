import XCTest

// These end-to-end regressions retain staged narratives and observed timeout
// values so failures identify the exact viewport phase.
// swiftlint:disable function_body_length no_magic_numbers trailing_newline

extension ConversationTranscriptScrollUITests {
    /// Reproduces #338 by releasing the hooks row immediately after each
    /// cold entry reports settled.
    @MainActor
    func testHooksRowLandingRightAfterColdEntryKeepsLastMessageOnScreen() throws {
        // Launches that reached the settle assertion: the denominator the
        // evidence attachments carry for this organic scenario.
        var settledLaunches = 0
        for cycle in 1 ... Fixture.entryCycles {
            let context = "cold entry \(cycle)/\(Fixture.entryCycles) with the hooks row released on settle"
            try? FileManager.default.removeItem(at: hooksRowTriggerFile)
            let app = launchDemoApp(
                hooksRowTriggerFile: hooksRowTriggerFile,
                blockHydrationTriggerFile: blockHydrationTriggerFile
            )
            let endRow = EndRow.lastSuggestedPrompt(in: app)
            let opened = enterLongConversation(
                in: app,
                context: context,
                evidence: recoveryEvidence(cycle: cycle, endRow: endRow, settledLaunches: settledLaunches)
            )
            let lastMessage = opened.lastMessage
            let transcript = opened.transcript
            let hooksRow = app.staticTexts[Fixture.hooksRowLabel].firstMatch

            guard waitUntilSettled(
                on: lastMessage,
                named: "last assistant paragraph",
                in: opened,
                context: context,
                alsoReporting: (endRow.element, endRow.name)
            ) else {
                attachRecoveryEvidence()
                app.terminate()
                continue
            }
            settledLaunches += 1
            pendingRecoveryEvidence?.settledLaunches = settledLaunches
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
            attachRecoveryEvidence()
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

    /// The controlled counterpart of the hooks-row scenario: the transcript
    /// has settled at the end with no recovery episode in flight, then the
    /// fixture withdraws the `scroll-bottom` marker on the trigger file
    /// (`release` mode, see `Fixture.endDerealizationTriggerFileArgumentPrefix`),
    /// so the real unrealized-end recovery arms through the marker's own
    /// `onDisappear` exactly as it does over a dropped end row. The recovery
    /// must then run to its recovered outcome on its own — settle, page the
    /// live scroll view up, follow back, re-verify through the marker's real
    /// `onAppear` once the fixture has put it back — spending at least one
    /// correction, with the end row realized and at rest at the end and Go
    /// to End absent. The baseline is read once the entry has settled and
    /// its own report is terminal, so the episode counter proves the
    /// controlled episode, not an entry-time one, is the one that resolved.
    @MainActor
    func testControlledEndDerealizationIsRecoveredByTheRealRecoveryPath() throws {
        let context = "controlled end derealization, release mode"
        let app = launchDemoApp(
            hooksRowTriggerFile: hooksRowTriggerFile,
            endDerealization: EndDerealization(triggerFile: endDerealizationTriggerFile, mode: .release)
        )
        let endRow = EndRow.lastSuggestedPrompt(in: app)
        let opened = openLongConversation(
            in: app,
            context: context,
            evidence: recoveryEvidence(cycle: 1, endRow: endRow)
        )
        let lastMessage = opened.lastMessage

        // 1. Settled at the end with a terminal report: the baseline.
        guard let baseline = settledRecoveryBaseline(
            lastRow: lastMessage,
            endRow: endRow,
            in: opened,
            context: context
        ) else { return }

        // 2. Withdraw the marker; the recovery arms and runs out on its own.
        try Data().write(to: endDerealizationTriggerFile)
        let recovered = "\(context), after the recovery resolved"
        guard let terminal = waitForTerminalRecovery(
            after: baseline,
            endRow: endRow,
            in: opened,
            context: context
        ) else { return }
        attachRecoveryEvidence(context: recovered)

        // 3. Recovered by the real path: a correction spent, the end row
        //    realized, and the viewport back at rest at the end with Go to
        //    End absent over the quiet window.
        XCTAssertEqual(
            terminal.reason,
            Fixture.recoveredReason,
            "\(recovered): the recovery did not report recovered — \(terminal.raw)"
        )
        XCTAssertGreaterThanOrEqual(
            terminal.corrections,
            1,
            "\(recovered): recovered without spending a correction — \(terminal.raw)"
        )
        XCTAssertGreaterThan(
            terminal.episodes,
            baseline.episodes,
            "\(recovered): the episode counter did not advance past the baseline (\(baseline.raw)) — \(terminal.raw)"
        )
        XCTAssertTrue(
            terminal.endRealized,
            "\(recovered): recovered with the end row unrealized — \(terminal.raw)"
        )
        guard waitUntilSettled(
            on: lastMessage,
            named: "last assistant paragraph",
            in: opened,
            context: recovered,
            alsoReporting: (endRow.element, endRow.name)
        ) else { return }
        XCTAssertTrue(
            opened.goToEnd.waitForNonExistence(timeout: 5),
            "\(recovered): Go to End is shown — "
                + restingState(of: lastMessage, named: "last assistant paragraph", in: opened)
        )
        assertAtEnd(endRow, in: opened, context: recovered)
        assertStaysAtBottom(
            lastRow: lastMessage,
            named: "last assistant paragraph",
            endRow: endRow,
            in: opened,
            context: recovered
        )
    }

    /// The same controlled derealization in `hold` mode: the fixture never
    /// puts the marker back, so the recovery's follow back finds no end row
    /// and its landing budget runs out. It must give up — never report
    /// `recovered` — with the end row still unrealized and Go to End shown,
    /// the honest outcome over an end the transcript cannot reach.
    @MainActor
    func testControlledHeldEndDerealizationGivesUpAndShowsGoToEnd() throws {
        let context = "controlled end derealization, hold mode"
        let app = launchDemoApp(
            hooksRowTriggerFile: hooksRowTriggerFile,
            endDerealization: EndDerealization(triggerFile: endDerealizationTriggerFile, mode: .hold)
        )
        let endRow = EndRow.lastSuggestedPrompt(in: app)
        let opened = openLongConversation(
            in: app,
            context: context,
            evidence: recoveryEvidence(cycle: 1, endRow: endRow)
        )
        let lastMessage = opened.lastMessage

        // 1. Settled at the end with a terminal report: the baseline.
        guard let baseline = settledRecoveryBaseline(
            lastRow: lastMessage,
            endRow: endRow,
            in: opened,
            context: context
        ) else { return }

        // 2. Withdraw the marker for good; the recovery arms and exhausts
        //    its budget.
        try Data().write(to: endDerealizationTriggerFile)
        let gaveUp = "\(context), after the recovery resolved"
        guard let terminal = waitForTerminalRecovery(
            after: baseline,
            endRow: endRow,
            in: opened,
            context: context
        ) else { return }
        attachRecoveryEvidence(context: gaveUp)

        // 3. Gave up honestly: not recovered, the end row unrealized, Go to
        //    End offered.
        XCTAssertNotEqual(
            terminal.reason,
            Fixture.recoveredReason,
            "\(gaveUp): the recovery reported recovered over a withdrawn end row — \(terminal.raw)"
        )
        XCTAssertEqual(
            terminal.reason,
            Fixture.gaveUpReason,
            "\(gaveUp): the recovery did not give up — \(terminal.raw)"
        )
        XCTAssertFalse(
            terminal.endRealized,
            "\(gaveUp): the end row reads realized while the fixture holds the marker withdrawn — \(terminal.raw)"
        )
        XCTAssertTrue(
            opened.goToEnd.waitForExistence(timeout: 5),
            "\(gaveUp): Go to End is not shown after the recovery gave up — "
                + restingState(of: lastMessage, named: "last assistant paragraph", in: opened)
        )
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
            assertAtEnd(
                endRow,
                in: opened,
                context: "\(context), after expanding the slim tool row"
            )
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

// MARK: - Per-launch recovery evidence

// The evidence helpers are shared with the cold-entry test in the main file
// and its teardown.
// swiftlint:disable test_case_accessibility
extension ConversationTranscriptScrollUITests {
    /// The arming `enterLongConversation` performs before its first
    /// assertion: the record it builds lands in `pendingRecoveryEvidence`.
    /// `attachRecoveryEvidence` takes the record on the ordinary path, and
    /// `tearDownWithError` takes it when a failing assertion halted the
    /// test first, so every launch leaves one whether it passed, failed,
    /// never settled or never showed its transcript.
    @MainActor
    func recoveryEvidence(cycle: Int, endRow: EndRow, settledLaunches: Int? = nil) -> RecoveryEvidenceArming {
        RecoveryEvidenceArming(cycle: cycle, endRow: endRow, settledLaunches: settledLaunches) { pending in
            self.pendingRecoveryEvidence = pending
        }
    }

    /// Attaches the armed launch's record now, under `context` when given
    /// (the phase the record describes); fails when no launch is armed.
    @MainActor
    func attachRecoveryEvidence(context: String? = nil) {
        guard pendingRecoveryEvidence != nil else {
            XCTFail("\(context ?? testMethodName): no launch is armed for a recovery evidence record")
            return
        }
        if let context {
            pendingRecoveryEvidence?.context = context
        }
        attachPendingRecoveryEvidence()
    }

    /// Attaches the armed launch's content-free evidence record as JSON
    /// (`Fixture.evidenceAttachmentPrefix`, kept always; see
    /// `recoveryEvidenceRecord`), if one is armed, and disarms the launch.
    @MainActor
    func attachPendingRecoveryEvidence() {
        guard let pending = pendingRecoveryEvidence else { return }
        pendingRecoveryEvidence = nil
        let record = recoveryEvidenceRecord(of: pending, test: testMethodName)
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        else {
            XCTFail("\(pending.context): the recovery evidence record could not be serialized")
            return
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "\(Fixture.evidenceAttachmentPrefix)-\(testMethodName)-\(pending.cycle)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The bare test method name out of `name` (`-[Class testMethod]`).
    private var testMethodName: String {
        let tail = name.split(separator: " ").last.map { String($0) } ?? name
        return tail.trimmingCharacters(in: CharacterSet(charactersIn: "]"))
    }
}
// swiftlint:enable test_case_accessibility
// swiftlint:enable function_body_length no_magic_numbers trailing_newline