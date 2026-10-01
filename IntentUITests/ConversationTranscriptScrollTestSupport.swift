import XCTest

// Shared diagnostics stay together so every failure reports the same state.
// swiftlint:disable file_length

@MainActor
func transcriptScreenshot(in app: XCUIApplication, named name: String) -> XCTAttachment {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    return attachment
}

enum Fixture {
    static let workspaceTitle = "Deflake payment integration tests"
    static let workspaceListIdentifier = "workspaces.search.open"
    // DemoFixtures.longConversationAgents' top-level agent name: the row
    // tapped on the workspace overview to reach the transcript.
    static let agentName = "Test Stabilizer"
    // WorkspaceDetailView's Agents/Context segmented control: an
    // overview-only surface.
    static let overviewOnlyButton = "Context"
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
    static let firstSuggestedPrompt =
        "Open a [**PR**](https://github.com/intent-hq/ios) for the `deflake` changes"
    static let firstSuggestedPromptLabel = "Open a PR for the deflake changes"
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
    // Workspace iPhone: 32pt section gap plus the 8pt anchor and 12pt footer.
    // The shared non-phone presentation retains the original 16pt section gap.
    private static let workspaceEndRowGap: CGFloat = 52
    private static let legacyEndRowGap: CGFloat = 36

    @MainActor static var endRowGap: CGFloat {
        UIDevice.current.userInterfaceIdiom == .phone ? workspaceEndRowGap : legacyEndRowGap
    }
    // Slack on `endRowGap`: the follow lands within 1 pt
    // (Constants.Conversation.Transcript.followLandingTolerance) and
    // accessibility frames round to the pixel grid.
    static let endGapTolerance: CGFloat = 4
    // Entry symptoms are intermittent; each cycle is a fresh entry.
    static let entryCycles = 5
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
    static let blockHydrationTriggerFileArgumentPrefix = "--demo-block-hydration-trigger-file="
    static let blockHydrationTimeout: TimeInterval = 15
    static let slimToolRowLayoutArgumentPrefix = "--demo-long-slim-tool-rows="
    static let standaloneSlimToolRows = "standalone"
    static let truncatedToolFileName = "final_evidence_table.py"
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
    static let followReportPrefix = "lastForcedFollow="
    static let pendingFollowReport = "lastForcedFollow=pending"
    static let landedFollowReportPrefix = "lastForcedFollow=landed"
    // The `endRecovery=<reason> corrections=N episodes=N endRealized=<bool>`
    // segment the report carries once the follow has reported
    // (ConversationTranscriptScrollPolicy.UnrealizedEndRecoveryReport):
    // how the last unrealized-end recovery episode resolved. `reason` is
    // `notAttempted` before any episode, `recovering` while one is in
    // flight and terminal otherwise; `recovered` is earned only by an
    // episode that spent a correction and found the end row realized
    // when it resolved, which every settled report is checked against
    // (`assertRecoveryReportWellFormed`). Ordinary launches are not
    // held to `notAttempted`: the marker may transiently derealize
    // during entry, an episode the report classifies as
    // `noCorrectionNeeded`.
    static let endRecoveryReportPrefix = "endRecovery="
    static let recoveringReason = "recovering"
    static let recoveredReason = "recovered"
    static let gaveUpReason = "gaveUp"
    // Withdraws the transcript's `scroll-bottom` marker once this file
    // exists (DemoFixtures.configuredEndDerealizationTriggerFile), so the
    // real recovery arms through the marker's own `onDisappear` at a
    // moment the test chooses instead of the organic hooks-row timing.
    // `release` puts the marker back once the recovery has measurably
    // paged the live scroll view up, so its follow back re-verifies
    // through the marker's real `onAppear`; `hold` never does, so the
    // recovery runs out its landing budget. Only the two controlled
    // tests pass the argument.
    static let endDerealizationTriggerArgumentPrefix = "--demo-end-derealization-trigger-file="
    static let endDerealizationModeArgumentPrefix = "--demo-end-derealization-mode="
    // Upper bound on a recovery episode reporting a terminal reason: the
    // fixture's 100 ms trigger poll, then the recovery's own bounded
    // budget — settle polls, the page up, the follow back, or in `hold`
    // the 3 s landing timeout (Constants.Conversation.Transcript.
    // followLanding*) — with the same simulator margin as settleTimeout.
    static let recoveryTimeout: TimeInterval = 15
    // Name prefix of the per-launch evidence attachment (see
    // `attachRecoveryEvidence`): `<prefix>-<test method>-<cycle>`.
    static let evidenceAttachmentPrefix = "transcript-recovery-evidence"
    // Cadence of every poll.
    static let pollInterval: TimeInterval = 0.25
    // SubmittableTextView's UITextView; tapping it raises the software
    // keyboard, whose avoidance shrinks the transcript from below (#276).
    static let composerIdentifier = "composer.textView"
    static let keyboardTimeout: TimeInterval = 5
    // The transcript must lose at least this much height for the keyboard
    // to count as raised: a simulator with a hardware keyboard attached
    // raises none and would pass without exercising the inset.
    static let keyboardMinimumShrink: CGFloat = 100
    static let workspaceTimeout: TimeInterval = 30
    static let elementTimeout: TimeInterval = 5
    static let backNavigationAttempts = 2
    static let backNavigationTimeout: TimeInterval = 3
}

struct OpenConversation {
    let lastMessage: XCUIElement
    let goToEnd: XCUIElement
    let transcript: XCUIElement
}

/// The transcript's final content row — the row whose gap from the
/// bottom edge is `Fixture.endRowGap` when the viewport is at the end —
/// and how far its accessibility frame's bottom edge sits above the
/// row's own (a label inside a padded row).
struct EndRow {
    let element: XCUIElement
    let name: String
    let labelInset: CGFloat

    @MainActor
    static func lastSuggestedPrompt(in app: XCUIApplication) -> Self {
        Self(
            element: app.buttons[Fixture.endRowIdentifier].firstMatch,
            name: "last suggested prompt",
            labelInset: 0
        )
    }

    @MainActor
    static func thinkingIndicator(in app: XCUIApplication) -> Self {
        Self(
            element: app.staticTexts[Fixture.thinkingIndicatorLabel].firstMatch,
            name: "thinking indicator",
            labelInset: Fixture.thinkingIndicatorLabelInset
        )
    }
}

struct FooterBaseline {
    let hooksRow: XCUIElement
    let transcriptBottom: CGFloat
    let messageGap: CGFloat
}

/// `--demo-end-derealization-mode=` values (DemoFixtures.EndDerealizationMode).
enum EndDerealizationMode: String {
    case hold
    case release
}

/// The marker withdrawal a controlled-recovery launch arms: the trigger
/// file the fixture waits on and the mode it withdraws in.
struct EndDerealization {
    let triggerFile: URL
    let mode: EndDerealizationMode
}

/// The `endRecovery=…` segment of the transcript's accessibility value
/// (see `Fixture.endRecoveryReportPrefix`), parsed; nil while the value
/// carries none (the follow still pending).
struct EndRecoveryReport {
    let reason: String
    let corrections: Int
    let episodes: Int
    let endRealized: Bool
    /// The whole accessibility value, for messages.
    let raw: String

    init?(followReport: String) {
        guard let start = followReport.range(of: Fixture.endRecoveryReportPrefix)?.lowerBound else { return nil }
        var fields: [String: String] = [:]
        for token in followReport[start...].split(separator: " ") {
            let pair = token.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            fields[String(pair[0])] = String(pair[1])
        }
        guard let reason = fields["endRecovery"],
              let corrections = fields["corrections"].flatMap({ Int($0) }),
              let episodes = fields["episodes"].flatMap({ Int($0) }),
              let endRealized = fields["endRealized"].flatMap({ Bool($0) })
        else { return nil }
        self.reason = reason
        self.corrections = corrections
        self.episodes = episodes
        self.endRealized = endRealized
        raw = followReport
    }

    /// False while an episode is in flight.
    var isTerminal: Bool { reason != Fixture.recoveringReason }

    /// A control may observe a natural recovery before releasing its trigger.
    /// That episode is a baseline only, never proof of the triggered recovery.
    func canBeBaseline(allowRecoveredEntry: Bool = false) -> Bool {
        guard isTerminal else { return false }
        if reason != Fixture.recoveredReason { return true }
        return allowRecoveredEntry && corrections > 0 && endRealized
    }
}

/// A launch armed for its evidence record: what `attachRecoveryEvidence`
/// needs to take the snapshot, held until the record is attached.
struct PendingRecoveryEvidence {
    var context: String
    let cycle: Int
    var settledLaunches: Int?
    let opened: OpenConversation
    let endRow: EndRow
}

/// How `enterLongConversation` arms a launch for its evidence record
/// before the first assertion on it: the record's identity, and `arm`,
/// which hands the built record to the test case (see
/// `ConversationTranscriptScrollUITests.recoveryEvidence`).
struct RecoveryEvidenceArming {
    let cycle: Int
    let endRow: EndRow
    let settledLaunches: Int?
    let arm: @MainActor (PendingRecoveryEvidence) -> Void
}

/// Launches the demo app with footer and hydration responses held behind
/// their trigger files. `standaloneSlimToolRows` makes truncated tools
/// independently tappable for the opt-in hydration regression, and
/// `endDerealization` arms the marker withdrawal behind its trigger file
/// in the given mode (see `Fixture.endDerealizationTriggerArgumentPrefix`).
@MainActor
func launchDemoApp(
    hooksRowTriggerFile: URL,
    blockHydrationTriggerFile: URL? = nil,
    standaloneSlimToolRows: Bool = false,
    endDerealization: EndDerealization? = nil,
    extraArguments: [String] = []
) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["--demo-data", Fixture.hooksRowTriggerFileArgumentPrefix + hooksRowTriggerFile.path] + extraArguments
    if let blockHydrationTriggerFile {
        app.launchArguments.append(
            Fixture.blockHydrationTriggerFileArgumentPrefix + blockHydrationTriggerFile.path
        )
    }
    if standaloneSlimToolRows {
        app.launchArguments.append(Fixture.slimToolRowLayoutArgumentPrefix + Fixture.standaloneSlimToolRows)
    }
    if let endDerealization {
        app.launchArguments += [
            Fixture.endDerealizationTriggerArgumentPrefix + endDerealization.triggerFile.path,
            Fixture.endDerealizationModeArgumentPrefix + endDerealization.mode.rawValue
        ]
    }
    app.launch()
    return app
}

/// Taps the long-conversation workspace row, then its agent row on the
/// workspace overview (a workspace tap never auto-opens an agent, ios#349),
/// and waits for the transcript, Go to End button handle and scroll view.
/// A missing last message is
/// reported with the resting state (a viewport past the end may leave the
/// last row unrealized and off the accessibility hierarchy). `evidence`
/// arms the launch's evidence record before the first assertion (see
/// `enterLongConversation`).
@MainActor
func openLongConversation(
    in app: XCUIApplication,
    context: String = "after opening",
    evidence: RecoveryEvidenceArming? = nil
) -> OpenConversation {
    let opened = enterLongConversation(in: app, context: context, evidence: evidence)
    XCTAssertTrue(
        opened.lastMessage.waitForExistence(timeout: Fixture.settleTimeout),
        "\(context): last transcript message never appeared — "
            + restingState(of: opened.lastMessage, named: "last assistant paragraph", in: opened)
    )
    return opened
}

/// `openLongConversation` without waiting for the last message, so a
/// test can observe the transcript's very first settled state. The query
/// handles are built first and, with `evidence`, the launch is armed for
/// its evidence record before the workspace-row and agent-row taps and
/// the existence assertions, so a launch that never shows its transcript
/// leaves a record too (the flush reads absent elements as absent, never
/// asserts).
@MainActor
func enterLongConversation(
    in app: XCUIApplication,
    context: String,
    evidence: RecoveryEvidenceArming? = nil,
    waitForTranscript: Bool = true
) -> OpenConversation {
    let opened = OpenConversation(
        lastMessage: message(in: app, containing: Fixture.lastMessageFragment),
        goToEnd: app.buttons[Fixture.goToEndIdentifier].firstMatch,
        transcript: app.scrollViews[Fixture.transcriptIdentifier].firstMatch
    )
    if let evidence {
        evidence.arm(
            PendingRecoveryEvidence(
                context: context,
                cycle: evidence.cycle,
                settledLaunches: evidence.settledLaunches,
                opened: opened,
                endRow: evidence.endRow
            )
        )
    }

    let workspaceRow = app.staticTexts[Fixture.workspaceTitle].firstMatch
    if !workspaceRow.waitForExistence(timeout: Fixture.workspaceTimeout) {
        // Same fallback as AppStoreScreenshotTests: a collapsed iPad
        // sidebar hides the workspace list behind the first nav button.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(workspaceRow.waitForExistence(timeout: Fixture.settleTimeout))
    }
    workspaceRow.tap()

    // The Agents/Context switcher exists only on the overview; the agent
    // name alone would also match an already-open conversation's title.
    let overview = app.buttons[Fixture.overviewOnlyButton].firstMatch
    XCTAssertTrue(
        overview.waitForExistence(timeout: Fixture.settleTimeout),
        "\(context): workspace overview not shown after the workspace tap"
    )
    let agentRow = app.staticTexts[Fixture.agentName].firstMatch
    XCTAssertTrue(
        agentRow.waitForExistence(timeout: Fixture.settleTimeout),
        "\(context): agent row not found on the workspace overview"
    )
    agentRow.tap()

    if waitForTranscript {
        XCTAssertTrue(
            opened.transcript.waitForExistence(timeout: Fixture.elementTimeout),
            "\(context): transcript scroll view not found"
        )
    }
    return opened
}

/// The transcript's static-text rows whose frames intersect its own
/// frame: empty when the viewport rests over a blank band. The hierarchy
/// is in flux while a cold entry (de)realizes rows, so each row's frame
/// is read from one snapshot (`frame(of:)`) and skipped when the row has
/// vanished rather than queried from a stale index, and an empty walk is
/// retried a few times.
@MainActor
func rows(intersecting transcript: XCUIElement) -> [XCUIElement] {
    let rows = transcript.staticTexts
    for _ in 0 ..< Fixture.visibleBandAttempts {
        let transcriptFrame = transcript.frame
        var intersecting: [XCUIElement] = []
        for index in 0 ..< rows.count {
            let row = rows.element(boundBy: index)
            if let rowFrame = frame(of: row), rowFrame.intersects(transcriptFrame) {
                intersecting.append(row)
            }
        }
        if !intersecting.isEmpty {
            return intersecting
        }
        RunLoop.current.run(until: Date().addingTimeInterval(Fixture.pollInterval))
    }
    return []
}

/// Row enumeration uses live indices which can retarget when lazy descendants
/// change. Startup fixture labels are unique; retain that identity for every
/// geometry sample across metadata release and same-view reappearance.
@MainActor
func startupVisibleRow(_ opened: OpenConversation) throws -> XCUIElement {
    var selected: XCUIElement?
    XCTAssertTrue(waitUntil(timeout: Fixture.settleTimeout) {
        guard let candidate = rows(intersecting: opened.transcript).first(where: { row in
            row.label.hasPrefix("Startup row") && isInside(row, opened.transcript)
        }), let snapshot = try? candidate.snapshot(), snapshot.label.hasPrefix("Startup row") else { return false }
        let matches = opened.transcript.staticTexts.matching(NSPredicate(format: "label == %@", snapshot.label))
        guard matches.count == 1 else { return false }
        let row = matches.firstMatch
        guard isInside(row, opened.transcript) else { return false }
        selected = row
        return true
    })
    return try XCTUnwrap(selected)
}

/// Navigates back out of the transcript to the workspace list so the
/// next `openLongConversation` is a fresh entry; relaunches when no back
/// path leads there (a split view keeps the transcript in its detail column).
/// Gates on the list's search button: the workspace title alone also
/// exists on the overview (its navigation title) and on the transcript
/// (its back button), where tapping it navigates nowhere.
@MainActor
func leaveConversation(in app: XCUIApplication) {
    let workspaceList = app.buttons[Fixture.workspaceListIdentifier].firstMatch
    let workspaceRow = app.staticTexts[Fixture.workspaceTitle].firstMatch
    var backTapsLeft = Fixture.backNavigationAttempts
    while backTapsLeft > 0, !workspaceList.waitForExistence(timeout: Fixture.backNavigationTimeout) {
        let workspaceBack = app.buttons["conversation.back"]
        let back = workspaceBack.exists ? workspaceBack : app.navigationBars.buttons.element(boundBy: 0)
        guard back.exists else { break }
        back.tap()
        backTapsLeft -= 1
    }
    if !workspaceList.exists || !workspaceRow.waitForExistence(timeout: Fixture.elementTimeout) {
        app.launch()
    }
}

@MainActor
func swipeDown(_ transcript: XCUIElement, times: Int) {
    for _ in 0 ..< times {
        transcript.swipeDown()
    }
}

@MainActor
func footerBaseline(
    in app: XCUIApplication,
    opened: OpenConversation,
    endRow: EndRow
) -> FooterBaseline? {
    guard waitUntilSettled(
        on: opened.lastMessage,
        named: "last assistant paragraph",
        in: opened,
        context: "before the hooks row",
        allowPreservedEntry: true,
        alsoReporting: (endRow.element, endRow.name)
    ) else { return nil }
    assertAtEnd(endRow, in: opened, context: "before the hooks row")
    let hooksRow = app.staticTexts[Fixture.hooksRowLabel].firstMatch
    XCTAssertFalse(hooksRow.exists, "hooks row was already present when the transcript settled")
    let gap = { opened.transcript.frame.maxY - (frame(of: opened.lastMessage)?.maxY ?? .nan) }
    guard let steadyGap = waitUntilSteady(timeout: Fixture.elementTimeout, tolerance: Fixture.rePinTolerance, gap) else {
        XCTFail("transcript kept moving after it settled; no steady baseline gap")
        return nil
    }
    XCTAssertFalse(hooksRow.exists, "hooks row was already present when the baseline gap was recorded")
    return FooterBaseline(
        hooksRow: hooksRow,
        transcriptBottom: opened.transcript.frame.maxY,
        messageGap: steadyGap
    )
}

/// Asserts the transcript rests at the end with `lastRow` as its last
/// row: `waitUntilSettled`, then `assertAtEnd` on `endRow`, then
/// `assertStaysAtBottom`.
@MainActor
func assertRestsAtBottom(
    lastRow: XCUIElement,
    named rowName: String,
    endRow: EndRow,
    in opened: OpenConversation,
    context: String,
    allowPreservedEntry: Bool = false
) {
    guard waitUntilSettled(
        on: lastRow,
        named: rowName,
        in: opened,
        context: context,
        allowPreservedEntry: allowPreservedEntry,
        alsoReporting: (endRow.element, endRow.name)
    ) else { return }
    assertAtEnd(endRow, in: opened, context: context)
    assertStaysAtBottom(lastRow: lastRow, named: rowName, endRow: endRow, in: opened, context: context)
}

/// The one settlement wait. Polls until the transcript has come to rest
/// with `lastRow` at its end: the last forced follow has reported an
/// outcome, or entry deliberately preserved a visible viewport without ever
/// requesting a forced follow. Both paths require an idle viewport; the row's
/// frame lies inside the transcript's frame, and the row has held still
/// across two consecutive polls. A row the lazy stack has not realized
/// (viewport past the end) never satisfies this. Fails the test — with
/// the follow's report and the resting state of the row and of
/// `alsoReporting` — when that does not happen within
/// `Fixture.settleTimeout`, and returns whether it did so callers can
/// stop instead of asserting on a transcript still in motion.
@MainActor @discardableResult
func waitUntilSettled(
    on lastRow: XCUIElement,
    named rowName: String,
    in opened: OpenConversation,
    context: String,
    allowPreservedEntry: Bool = false,
    forcedFollowAfter: Int? = nil,
    recoveryAfter: Int? = nil,
    alsoReporting extra: (row: XCUIElement, name: String)? = nil
) -> Bool {
    let transcript = opened.transcript
    var previousMaxY: CGFloat = .nan
    let settled = waitUntil(timeout: Fixture.settleTimeout) {
        guard viewportHasReportedSettlement(
            followReport(in: opened),
            allowPreservedEntry: allowPreservedEntry,
            forcedFollowAfter: forcedFollowAfter,
            recoveryAfter: recoveryAfter
        ),
              let rowFrame = frame(of: lastRow) else {
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
    } else {
        assertRecoveryReportWellFormed(in: opened, context: context)
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
func assertAtEnd(_ endRow: EndRow, in opened: OpenConversation, context: String) {
    XCTAssertTrue(
        isAtEnd(endRow, in: opened.transcript),
        "\(context): the settled transcript is not at the end — the \(endRow.name), its final content row, "
            + "does not rest \(Int(Fixture.endRowGap + endRow.labelInset)) ± \(Int(Fixture.endGapTolerance)) pt "
            + "above the bottom edge — " + restingState(of: endRow.element, named: endRow.name, in: opened)
    )
}

/// Over `Fixture.quietWindow` after the transcript has settled, Go to
/// End must never appear, `lastRow` must stay inside the transcript's
/// frame and `endRow` must stay at the end: a late correction, re-pin
/// or automatic follow that moves the rows shows up here. The failure
/// message carries `restingState`.
@MainActor
func assertStaysAtBottom(
    lastRow: XCUIElement,
    named rowName: String,
    endRow: EndRow,
    in opened: OpenConversation,
    context: String
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
            + restingState(of: endRow.element, named: endRow.name, in: opened)
    )
    assertRecoveryReportWellFormed(in: opened, context: context)
}

/// The shape guard on every settled report: `recovered` may only be
/// claimed by an episode that spent a correction and found the end row
/// realized (see `Fixture.endRecoveryReportPrefix`). Any other reason,
/// or a report without the segment, passes — ordinary launches are not
/// held to `notAttempted`.
@MainActor
func assertRecoveryReportWellFormed(in opened: OpenConversation, context: String) {
    guard let report = recoveryReport(in: opened), report.reason == Fixture.recoveredReason else { return }
    XCTAssertTrue(
        report.endRealized && report.corrections >= 1,
        "\(context): the report claims a recovered end row without the evidence for it "
            + "(recovered requires endRealized=true and corrections>=1) — \(report.raw)"
    )
}

/// The controlled tests' baseline: `waitUntilSettled` on `lastRow`,
/// `assertAtEnd` on `endRow`, then the `endRecovery` report once it is
/// terminal — an entry-time episode may still be in flight when the
/// follow reports. Legacy controls require a non-recovered baseline; a
/// control that allows entry recovery must still require a newer episode
/// after its trigger. Fails the test when the baseline is not allowed.
@MainActor
func settledRecoveryBaseline(
    lastRow: XCUIElement,
    endRow: EndRow,
    in opened: OpenConversation,
    context: String,
    allowRecoveredEntry: Bool = false
) -> EndRecoveryReport? {
    guard waitUntilSettled(
        on: lastRow,
        named: "last assistant paragraph",
        in: opened,
        context: context,
        allowPreservedEntry: true,
        alsoReporting: (endRow.element, endRow.name)
    ) else { return nil }
    assertAtEnd(endRow, in: opened, context: context)
    var report = recoveryReport(in: opened)
    let terminal = waitUntil(timeout: Fixture.recoveryTimeout) {
        report = recoveryReport(in: opened)
        return report?.isTerminal == true
    }
    guard terminal, let baseline = report else {
        XCTFail(
            "\(context): no terminal endRecovery report within \(Int(Fixture.recoveryTimeout)) s of settling, "
                + "before the trigger file — " + restingState(of: endRow.element, named: endRow.name, in: opened)
        )
        return nil
    }
    XCTAssertTrue(
        baseline.canBeBaseline(allowRecoveredEntry: allowRecoveredEntry),
        "\(context): the pre-trigger report is not an allowed settled baseline — \(baseline.raw)"
    )
    return baseline
}

/// Polls until an episode after `baseline` — a higher episode count —
/// has reported a terminal reason, within `Fixture.recoveryTimeout` of
/// the trigger file; fails the test and returns nil otherwise.
@MainActor
func waitForTerminalRecovery(
    after baseline: EndRecoveryReport,
    endRow: EndRow,
    in opened: OpenConversation,
    context: String
) -> EndRecoveryReport? {
    var latest: EndRecoveryReport?
    let resolved = waitUntil(timeout: Fixture.recoveryTimeout) {
        latest = recoveryReport(in: opened)
        guard let latest else { return false }
        return latest.episodes > baseline.episodes && latest.isTerminal
    }
    guard resolved, let latest else {
        XCTFail(
            "\(context): no recovery episode after the baseline (\(baseline.raw)) reported a terminal reason "
                + "within \(Int(Fixture.recoveryTimeout)) s of the trigger file — "
                + restingState(of: endRow.element, named: endRow.name, in: opened)
        )
        return nil
    }
    return latest
}

/// The `endRecovery=…` segment of the follow report, parsed; nil while
/// the report carries none.
@MainActor
func recoveryReport(in opened: OpenConversation) -> EndRecoveryReport? {
    EndRecoveryReport(followReport: followReport(in: opened))
}

/// The content-free evidence record of an armed launch (see
/// `attachRecoveryEvidence`): the follow report and its parsed
/// `endRecovery` fields, Go to End presence, the end row's gap from the
/// transcript's bottom edge and where its frame lies (ABOVE / INSIDE /
/// BELOW / CLIPPED_TOP / CLIPPED_BOTTOM / UNREALIZED, the classification
/// `restingState` spells out, or NO_TRANSCRIPT), the transcript frame, a
/// timestamp — and, for a repeated scenario, `settledLaunches`, the
/// launches that had reached the settle assertion. No message text or
/// fixture strings. The transcript is read from one `snapshot()` and
/// every field it feeds is null when it is absent: the record is taken
/// from teardown after a failed launch too, so it never asserts.
@MainActor
func recoveryEvidenceRecord(of pending: PendingRecoveryEvidence, test testMethodName: String) -> [String: Any] {
    let opened = pending.opened
    let transcript = try? opened.transcript.snapshot()
    let report = transcript?.value as? String
    let parsed = report.flatMap { EndRecoveryReport(followReport: $0) }
    let transcriptFrame = transcript?.frame
    let rowFrame = frame(of: pending.endRow.element)
    var gap: Double?
    if let transcriptFrame, let rowFrame {
        gap = Double(transcriptFrame.maxY - rowFrame.maxY)
    }
    var record: [String: Any] = [
        "test": testMethodName,
        "cycle": pending.cycle,
        "context": pending.context,
        "followReport": jsonValue(report),
        "goToEndPresent": opened.goToEnd.exists,
        "transcriptFrame": jsonValue(transcriptFrame.map { evidenceRecord(of: $0) }),
        "endRecovery": jsonValue(parsed.map { evidenceRecord(of: $0) }),
        "endRowPosition": evidencePosition(of: rowFrame, in: transcriptFrame),
        "endRowGap": jsonValue(gap),
        "endRowFrame": jsonValue(rowFrame.map { evidenceRecord(of: $0) }),
        "timestamp": ISO8601DateFormatter().string(from: Date())
    ]
    if let settledLaunches = pending.settledLaunches {
        record["settledLaunches"] = settledLaunches
    }
    return record
}

/// Where `rowFrame` lies relative to `transcriptFrame`, for the evidence
/// record: NO_TRANSCRIPT when the transcript is absent, UNREALIZED when
/// the row is.
func evidencePosition(of rowFrame: CGRect?, in transcriptFrame: CGRect?) -> String {
    guard let transcriptFrame else { return "NO_TRANSCRIPT" }
    guard let rowFrame else { return "UNREALIZED" }
    return if rowFrame.maxY <= transcriptFrame.minY {
        "ABOVE"
    } else if rowFrame.minY >= transcriptFrame.maxY {
        "BELOW"
    } else if isInside(rowFrame, transcriptFrame) {
        "INSIDE"
    } else if rowFrame.minY < transcriptFrame.minY {
        "CLIPPED_TOP"
    } else {
        "CLIPPED_BOTTOM"
    }
}

func evidenceRecord(of report: EndRecoveryReport) -> [String: Any] {
    [
        "reason": report.reason,
        "corrections": report.corrections,
        "episodes": report.episodes,
        "endRealized": report.endRealized
    ]
}

func evidenceRecord(of rect: CGRect) -> [String: Double] {
    ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
}

/// `value` for a JSON record, `NSNull` when absent.
func jsonValue(_ value: Any?) -> Any {
    value ?? NSNull()
}

/// True when `endRow` is realized, lies inside the transcript and its
/// frame's bottom edge sits `Fixture.endRowGap` (plus the row's label
/// inset) above the transcript's bottom edge, within
/// `Fixture.endGapTolerance`: the viewport is at the end — not short of
/// it with the marker (or rows) below, not past it over a blank band.
@MainActor
func isAtEnd(_ endRow: EndRow, in transcript: XCUIElement) -> Bool {
    guard let rowFrame = frame(of: endRow.element), isInside(rowFrame, transcript) else { return false }
    let gap = transcript.frame.maxY - rowFrame.maxY
    return abs(gap - (Fixture.endRowGap + endRow.labelInset)) <= Fixture.endGapTolerance
}

/// The transcript's accessibility value: the last forced follow's report
/// (see `Fixture.followReportPrefix`), or a placeholder when absent.
@MainActor
func followReport(in opened: OpenConversation) -> String {
    (opened.transcript.value as? String) ?? "<no transcript value>"
}

/// UIKit flags can change without another SwiftUI render. This startup-only
/// probe samples them on each accessibility query and fails closed if absent.
@MainActor
func waitUntilStartupGestureEnded(in app: XCUIApplication) -> Bool {
    let probe = app.descendants(matching: .any).matching(identifier: "transcript.gestureState").firstMatch
    var report = "<unavailable>"
    let ended = waitUntil(timeout: Fixture.settleTimeout) {
        guard probe.exists else { return false }
        report = probe.value as? String ?? "<unavailable>"
        return report.hasPrefix("phase=idle ")
    }
    XCTAssertTrue(ended, "release metadata only after the real gesture/deceleration has ended: \(report)")
    return ended
}

/// No forced result is fabricated for late entry. Once a forced request has
/// actually started, it must report a terminal outcome before any later settle.
func viewportHasReportedSettlement(
    _ report: String, allowPreservedEntry: Bool = false, forcedFollowAfter: Int? = nil, recoveryAfter: Int? = nil
) -> Bool {
    guard report.hasPrefix(Fixture.followReportPrefix),
          report.contains("followActive=false"), report.contains("phase=idle") else { return false }
    if let recovery = EndRecoveryReport(followReport: report), !recovery.isTerminal { return false }
    if let forcedFollowAfter {
        guard let count = forcedFollowRequestCount(report), count > forcedFollowAfter else { return false }
    }
    if let recoveryAfter {
        guard let recovery = EndRecoveryReport(followReport: report) else { return false }
        return recovery.isTerminal && recovery.reason == Fixture.recoveredReason
            && recovery.episodes > recoveryAfter && recovery.corrections > 0 && recovery.endRealized
    }
    if !report.hasPrefix(Fixture.pendingFollowReport) { return true }
    return allowPreservedEntry && report.contains("entry=preserved") && report.contains("metadataReady=true")
        && report.contains("forcedRequested=false")
}

func forcedFollowRequestCount(_ report: String) -> Int? {
    report.split(separator: " ")
        .first { $0.hasPrefix("forcedRequests=") }
        .flatMap { Int($0.dropFirst("forcedRequests=".count)) }
}

@MainActor
func forcedFollowRequestCount(in opened: OpenConversation) -> Int {
    guard let count = forcedFollowRequestCount(followReport(in: opened)) else {
        XCTFail("The transcript did not report its forced-follow request count")
        return .max
    }
    return count
}

/// The element's frame from a single snapshot; nil when the element is
/// not in the accessibility hierarchy or has no size. `exists` followed
/// by `frame` resolves the query twice, and a lazy-stack row that
/// derealizes in between fails the test instead of reading as absent.
@MainActor
func frame(of element: XCUIElement) -> CGRect? {
    guard let frame = (try? element.snapshot())?.frame, !frame.isEmpty else { return nil }
    return frame
}

/// True when the element's whole frame lies inside the container's frame
/// (within `rePinTolerance` for rounding).
@MainActor
func isInside(_ element: XCUIElement, _ container: XCUIElement) -> Bool {
    guard let elementFrame = frame(of: element) else { return false }
    return isInside(elementFrame, container)
}

@MainActor
func isInside(_ frame: CGRect, _ container: XCUIElement) -> Bool {
    isInside(frame, container.frame)
}

func isInside(_ frame: CGRect, _ containerFrame: CGRect) -> Bool {
    containerFrame.insetBy(dx: 0, dy: -Fixture.rePinTolerance).contains(frame)
}

/// Diagnostic sentence for failure messages: the last forced follow's
/// report, Go to End presence and where `row`'s frame lies relative to
/// the transcript's frame — ABOVE it means the viewport rests past the
/// end (blank band), BELOW it means the viewport rests short of the end
/// — with the row's gap from the transcript's bottom edge.
@MainActor
func restingState(of row: XCUIElement, named rowName: String, in opened: OpenConversation) -> String {
    let transcriptFrame = opened.transcript.frame
    let state = "\(followReport(in: opened)); " + (opened.goToEnd.exists ? "Go to End PRESENT" : "Go to End absent")
    guard let rowFrame = frame(of: row) else {
        return "\(state); \(rowName) is not in the accessibility hierarchy (unrealized / off screen); "
            + "transcript frame \(transcriptFrame)"
    }
    let position = if rowFrame.maxY <= transcriptFrame.minY {
        "ABOVE the transcript (viewport rests past the end)"
    } else if rowFrame.minY >= transcriptFrame.maxY {
        "BELOW the transcript (viewport rests short of the end)"
    } else if isInside(rowFrame, opened.transcript) {
        "inside the transcript"
    } else if rowFrame.minY < transcriptFrame.minY {
        "clipped by the transcript's top edge (partly past the end)"
    } else {
        "clipped by the transcript's bottom edge (partly short of the end)"
    }
    let gap = transcriptFrame.maxY - rowFrame.maxY
    return "\(state); \(rowName) frame \(rowFrame) is \(position), its bottom edge \(gap) pt above "
        + "the transcript's; transcript frame \(transcriptFrame)"
}

@MainActor
func message(in app: XCUIApplication, containing fragment: String) -> XCUIElement {
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
func waitUntilVisible(
    _ element: XCUIElement,
    in container: XCUIElement,
    timeout: TimeInterval
) -> Bool {
    waitUntil(timeout: timeout) { isVisible(element, in: container) }
}

/// True when the element exists and its centre lies inside the
/// container's frame right now.
@MainActor
func isVisible(_ element: XCUIElement, in container: XCUIElement) -> Bool {
    guard let elementFrame = frame(of: element) else { return false }
    return container.frame.contains(CGPoint(x: elementFrame.midX, y: elementFrame.midY))
}

/// Polls `condition` every `Fixture.pollInterval` until it holds or
/// `timeout` elapses.
@MainActor
func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() {
            return true
        }
        RunLoop.current.run(until: Date().addingTimeInterval(Fixture.pollInterval))
    } while Date() < deadline
    return false
}

/// Samples `value` every `Fixture.pollInterval` and returns it once two
/// consecutive samples agree within `tolerance`; nil if that never
/// happens before `timeout` elapses (a NaN sample never agrees).
@MainActor
func waitUntilSteady(
    timeout: TimeInterval,
    tolerance: CGFloat,
    _ value: () -> CGFloat
) -> CGFloat? {
    let deadline = Date().addingTimeInterval(timeout)
    var previous = value()
    repeat {
        RunLoop.current.run(until: Date().addingTimeInterval(Fixture.pollInterval))
        let current = value()
        if abs(current - previous) <= tolerance {
            return current
        }
        previous = current
    } while Date() < deadline
    return nil
}
extension ConversationTranscriptScrollUITests {
    @MainActor
    func attachStartupViewport(_ app: XCUIApplication, opened: OpenConversation, report: String, row: XCUIElement, context: String) {
        let snapshot = try? row.snapshot()
        let probe = app.descendants(matching: .any).matching(identifier: "transcript.gestureState").firstMatch
        let live = probe.exists ? probe.value : nil
        let attachment = XCTAttachment(string: "\(context): row=\(snapshot?.label ?? "missing") frame=\(String(describing: snapshot?.frame))"
            + " transcript=\(opened.transcript.frame) \(report) \(followReport(in: opened)) live=\(String(describing: live))")
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

// swiftlint:enable file_length
