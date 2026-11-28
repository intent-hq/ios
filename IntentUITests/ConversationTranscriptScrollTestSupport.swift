import XCTest

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
    static let agentName = "Test Stabilizer"
    static let overviewOnlyButton = "Context"
    static let firstMessageFragment = "Start of the flake investigation"
    static let lastMessageFragment = "End of the flake investigation"
    static let goToEndIdentifier = "transcript.goToEnd"
    static let firstSuggestedPromptIdentifier = "transcript.suggestedPrompt.0"
    static let firstSuggestedPromptLabel = "Open a PR for the deflake changes"
    static let endRowIdentifier = "transcript.suggestedPrompt.2"
    static let thinkingIndicatorLabel = "Thinking…"
    static let thinkingIndicatorLabelInset: CGFloat = 4
    private static let workspaceEndRowGap: CGFloat = 52
    private static let iPadEndRowGap: CGFloat = 56
    private static let legacyEndRowGap: CGFloat = 36

    @MainActor static var endRowGap: CGFloat {
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: workspaceEndRowGap
        case .pad: iPadEndRowGap
        default: legacyEndRowGap
        }
    }
    static let endGapTolerance: CGFloat = 4
    static let entryCycles = 5
    static let settleTimeout: TimeInterval = 15
    static let quietWindow: TimeInterval = 3
    static let transcriptIdentifier = "transcript.scrollView"
    static let hooksRowLabel = "Running hooks"
    static let hookName = "Wait for CI on flake fix"
    static let hooksRowTriggerFileArgumentPrefix = "--demo-hook-list-trigger-file="
    static let hooksRowTimeout: TimeInterval = 15
    static let blockHydrationTriggerFileArgumentPrefix = "--demo-block-hydration-trigger-file="
    static let blockHydrationTimeout: TimeInterval = 15
    static let slimToolRowLayoutArgumentPrefix = "--demo-long-slim-tool-rows="
    static let standaloneSlimToolRows = "standalone"
    static let truncatedToolFileName = "final_evidence_table.py"
    static let hydrationHintFragment = "full content"
    static let rePinTolerance: CGFloat = 4
    static let maxSwipesToTop = 150
    static let visibleBandAttempts = 3
    static let followReportPrefix = "lastForcedFollow="
    static let pendingFollowReport = "lastForcedFollow=pending"
    static let landedFollowReportPrefix = "lastForcedFollow=landed"
    static let endRecoveryReportPrefix = "endRecovery="
    static let recoveringReason = "recovering"
    static let recoveredReason = "recovered"
    static let gaveUpReason = "gaveUp"
    static let endDerealizationTriggerArgumentPrefix = "--demo-end-derealization-trigger-file="
    static let endDerealizationModeArgumentPrefix = "--demo-end-derealization-mode="
    static let recoveryTimeout: TimeInterval = 15
    static let evidenceAttachmentPrefix = "transcript-recovery-evidence"
    static let pollInterval: TimeInterval = 0.25
    static let composerIdentifier = "composer.textView"
    static let keyboardTimeout: TimeInterval = 5
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

enum EndDerealizationMode: String {
    case deepRelease = "deep-release"
    case hold
    case release
}

struct EndDerealization {
    let triggerFile: URL
    let mode: EndDerealizationMode
}

struct EndRecoveryReport {
    let reason: String
    let corrections: Int
    let episodes: Int
    let endRealized: Bool
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

    var isTerminal: Bool { reason != Fixture.recoveringReason }

    func canBeBaseline(allowRecoveredEntry: Bool = false) -> Bool {
        guard isTerminal else { return false }
        if reason != Fixture.recoveredReason { return true }
        return allowRecoveredEntry && corrections > 0 && endRealized
    }
}

struct PendingRecoveryEvidence {
    var context: String
    let cycle: Int
    var settledLaunches: Int?
    let opened: OpenConversation
    let endRow: EndRow
}

struct RecoveryEvidenceArming {
    let cycle: Int
    let endRow: EndRow
    let settledLaunches: Int?
    let arm: @MainActor (PendingRecoveryEvidence) -> Void
}

@MainActor
func launchDemoApp(
    hooksRowTriggerFile: URL,
    blockHydrationTriggerFile: URL? = nil,
    standaloneSlimToolRows: Bool = false,
    endDerealization: EndDerealization? = nil,
    extraArguments: [String] = []
) -> XCUIApplication {
    let app = XCUIApplication.intent()
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

@MainActor
func openLongConversation(
    in app: XCUIApplication,
    context: String = "after opening",
    evidence: RecoveryEvidenceArming? = nil
) -> OpenConversation {
    let opened = enterLongConversation(in: app, context: context, evidence: evidence)
    XCTAssertTrue(
        opened.lastMessage.appears(timeout: Fixture.settleTimeout),
        "\(context): last transcript message never appeared — "
            + restingState(of: opened.lastMessage, named: "last assistant paragraph", in: opened)
    )
    return opened
}

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
    if !workspaceRow.appears(timeout: Fixture.workspaceTimeout) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(workspaceRow.appears(timeout: Fixture.settleTimeout))
    }
    workspaceRow.tap()

    let overview = app.buttons[Fixture.overviewOnlyButton].firstMatch
    XCTAssertTrue(
        overview.appears(timeout: Fixture.settleTimeout),
        "\(context): workspace overview not shown after the workspace tap"
    )
    let agentRow = app.staticTexts[Fixture.agentName].firstMatch
    XCTAssertTrue(
        agentRow.appears(timeout: Fixture.settleTimeout),
        "\(context): agent row not found on the workspace overview"
    )
    agentRow.tap()

    if waitForTranscript {
        XCTAssertTrue(
            opened.transcript.appears(timeout: Fixture.elementTimeout),
            "\(context): transcript scroll view not found"
        )
    }
    return opened
}

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

@MainActor
func leaveConversation(in app: XCUIApplication) {
    let workspaceList = app.buttons[Fixture.workspaceListIdentifier].firstMatch
    let workspaceRow = app.staticTexts[Fixture.workspaceTitle].firstMatch
    var backTapsLeft = Fixture.backNavigationAttempts
    while backTapsLeft > 0, !workspaceList.appears(timeout: Fixture.backNavigationTimeout) {
        let workspaceBack = app.buttons["conversation.back"]
        let back = workspaceBack.exists ? workspaceBack : app.navigationBars.buttons.element(boundBy: 0)
        guard back.exists else { break }
        back.tap()
        backTapsLeft -= 1
    }
    if !workspaceList.exists || !workspaceRow.appears(timeout: Fixture.elementTimeout) {
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

@MainActor
func assertAtEnd(_ endRow: EndRow, in opened: OpenConversation, context: String) {
    XCTAssertTrue(
        isAtEnd(endRow, in: opened.transcript),
        "\(context): the settled transcript is not at the end — the \(endRow.name), its final content row, "
            + "does not rest \(Int(Fixture.endRowGap + endRow.labelInset)) ± \(Int(Fixture.endGapTolerance)) pt "
            + "above the bottom edge — " + restingState(of: endRow.element, named: endRow.name, in: opened)
    )
}

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

@MainActor
func assertRecoveryReportWellFormed(in opened: OpenConversation, context: String) {
    guard let report = recoveryReport(in: opened), report.reason == Fixture.recoveredReason else { return }
    XCTAssertTrue(
        report.endRealized && report.corrections >= 1,
        "\(context): the report claims a recovered end row without the evidence for it "
            + "(recovered requires endRealized=true and corrections>=1) — \(report.raw)"
    )
}

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

@MainActor
func recoveryReport(in opened: OpenConversation) -> EndRecoveryReport? {
    EndRecoveryReport(followReport: followReport(in: opened))
}

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

func jsonValue(_ value: Any?) -> Any {
    value ?? NSNull()
}

@MainActor
func isAtEnd(_ endRow: EndRow, in transcript: XCUIElement) -> Bool {
    guard let rowFrame = frame(of: endRow.element), isInside(rowFrame, transcript) else { return false }
    let gap = transcript.frame.maxY - rowFrame.maxY
    return abs(gap - (Fixture.endRowGap + endRow.labelInset)) <= Fixture.endGapTolerance
}

@MainActor
func followReport(in opened: OpenConversation) -> String {
    (opened.transcript.value as? String) ?? "<no transcript value>"
}

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

@MainActor
func frame(of element: XCUIElement) -> CGRect? {
    guard let frame = (try? element.snapshot())?.frame, !frame.isEmpty else { return nil }
    return frame
}

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

@MainActor
func waitUntilVisible(
    _ element: XCUIElement,
    in container: XCUIElement,
    timeout: TimeInterval
) -> Bool {
    waitUntil(timeout: timeout) { isVisible(element, in: container) }
}

@MainActor
func isVisible(_ element: XCUIElement, in container: XCUIElement) -> Bool {
    guard let elementFrame = frame(of: element) else { return false }
    return container.frame.contains(CGPoint(x: elementFrame.midX, y: elementFrame.midY))
}

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
