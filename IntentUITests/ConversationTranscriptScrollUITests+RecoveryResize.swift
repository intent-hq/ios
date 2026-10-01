import XCTest

extension ConversationTranscriptScrollUITests {
    /// The hooks response is released by the demo fixture only after the
    /// real recovery pages up. Missing that overlap fails the control: a
    /// quiet entry or a footer arriving after follow-back proves nothing.
    @MainActor
    func testHooksRowResizeKeepsRecoveryPagedUpUntilFollowBack() throws {
        let context = "footer resize during recovery page-up"
        let app = launchDemoApp(
            hooksRowTriggerFile: hooksRowTriggerFile,
            endDerealization: EndDerealization(triggerFile: endDerealizationTriggerFile, mode: .release),
            extraArguments: ["--demo-hooks-row-during-recovery"]
        )
        let endRow = EndRow.lastSuggestedPrompt(in: app)
        let opened = openLongConversation(in: app, context: context, evidence: recoveryEvidence(cycle: 1, endRow: endRow))
        guard let baseline = settledRecoveryBaseline(
            lastRow: opened.lastMessage, endRow: endRow, in: opened, context: context, allowRecoveredEntry: true
        ) else { return }
        XCTAssertFalse(app.staticTexts[Fixture.hooksRowLabel].firstMatch.exists)
        try Data().write(to: endDerealizationTriggerFile)
        guard let terminal = waitForTerminalRecovery(after: baseline, endRow: endRow, in: opened, context: context) else { return }
        attachRecoveryEvidence(context: context)
        XCTAssertTrue(app.staticTexts[Fixture.hooksRowLabel].firstMatch.exists, "The real hooks row never arrived")
        assertRecoveryResizeOverlap(in: opened)
        XCTAssertEqual(terminal.reason, Fixture.recoveredReason, terminal.raw)
        XCTAssertGreaterThanOrEqual(terminal.corrections, 1, terminal.raw)
        XCTAssertGreaterThan(terminal.episodes, baseline.episodes, terminal.raw)
        XCTAssertTrue(terminal.endRealized, terminal.raw)
        guard waitUntilSettled(
            on: opened.lastMessage,
            named: "last assistant paragraph",
            in: opened,
            context: context,
            recoveryAfter: baseline.episodes,
            alsoReporting: (endRow.element, endRow.name)
        ) else { return }
        XCTAssertFalse(opened.goToEnd.exists, terminal.raw)
        assertAtEnd(endRow, in: opened, context: context)
        assertStaysAtBottom(
            lastRow: opened.lastMessage, named: "last assistant paragraph", endRow: endRow, in: opened, context: context
        )
    }

    func testRecoveryResizeBaselineAllowsOnlyACompletedEntryRecovery() throws {
        let raw = "lastForcedFollow=landed corrections=0 "
            + "endRecovery=recovered corrections=1 episodes=2 endRealized=true "
            + "entry=positioned metadataReady=true forcedRequested=true followActive=false "
            + "forcedRequests=1 phase=idle workspace=demo-ws-flaky-tests resizeProbe=pending"
        let recovered = try XCTUnwrap(EndRecoveryReport(followReport: raw))
        XCTAssertFalse(recovered.canBeBaseline(), "Legacy controls retain their stricter baseline")
        XCTAssertTrue(recovered.canBeBaseline(allowRecoveredEntry: true))
        for (valid, invalid) in [
            ("corrections=1", "corrections=0"), ("endRealized=true", "endRealized=false"),
            ("endRecovery=recovered", "endRecovery=recovering")
        ] {
            let report = try XCTUnwrap(EndRecoveryReport(
                followReport: raw.replacingOccurrences(of: valid, with: invalid)
            ))
            XCTAssertFalse(report.canBeBaseline(allowRecoveredEntry: true), report.raw)
        }
        let untouched = try XCTUnwrap(EndRecoveryReport(
            followReport: "endRecovery=notAttempted corrections=0 episodes=0 endRealized=true"
        ))
        XCTAssertTrue(untouched.canBeBaseline())
        XCTAssertTrue(untouched.canBeBaseline(allowRecoveredEntry: true))
    }

    @MainActor
    private func assertRecoveryResizeOverlap(in opened: OpenConversation) {
        let report = followReport(in: opened)
        let fields = Dictionary(report.split(separator: " ").compactMap { token -> (String, String)? in
            let pair = token.split(separator: "=", maxSplits: 1)
            return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
        }) { _, latest in latest }
        XCTAssertEqual(fields["resizeOverlap"], "true", "The footer missed the recovery-owned page-up: \(report)")
        XCTAssertEqual(fields["followBackOwned"], "true", "Recovery lost ownership before follow-back: \(report)")
        guard let pageHeight = fields["pageUpHeight"].flatMap(Double.init),
              let pageDistance = fields["pageUpDistance"].flatMap(Double.init),
              let resizedHeight = fields["resizedHeight"].flatMap(Double.init),
              let preFollowHeight = fields["preFollowHeight"].flatMap(Double.init),
              let preFollowDistance = fields["preFollowDistance"].flatMap(Double.init)
        else {
            XCTFail("Missing actual page-up/resize/pre-follow geometry: \(report)")
            return
        }
        XCTAssertLessThan(resizedHeight, pageHeight, report)
        XCTAssertGreaterThanOrEqual(pageDistance, pageHeight / 2, "Recovery did not page up: \(report)")
        XCTAssertGreaterThanOrEqual(
            preFollowDistance,
            preFollowHeight / 2,
            "The footer displaced the paged-up viewport before recovery followed back: \(report)"
        )
    }
}
