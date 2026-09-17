import XCTest

// Shared diagnostics stay together so every failure reports the same state.
// swiftlint:disable file_length

enum Fixture {
    static let workspaceTitle = "Deflake payment integration tests"
    static let agentName = "Test Stabilizer"
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
    static let endRowGap: CGFloat = 36
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
    // Cadence of every poll.
    static let pollInterval: TimeInterval = 0.25
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

/// Launches the demo app with footer and hydration responses held behind
/// their trigger files. `standaloneSlimToolRows` makes truncated tools
/// independently tappable for the opt-in hydration regression.
@MainActor
func launchDemoApp(
    hooksRowTriggerFile: URL,
    blockHydrationTriggerFile: URL? = nil,
    standaloneSlimToolRows: Bool = false
) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["--demo-data", Fixture.hooksRowTriggerFileArgumentPrefix + hooksRowTriggerFile.path]
    if let blockHydrationTriggerFile {
        app.launchArguments.append(
            Fixture.blockHydrationTriggerFileArgumentPrefix + blockHydrationTriggerFile.path
        )
    }
    if standaloneSlimToolRows {
        app.launchArguments.append(Fixture.slimToolRowLayoutArgumentPrefix + Fixture.standaloneSlimToolRows)
    }
    app.launch()
    return app
}

/// Taps the long-conversation workspace and agent rows, then waits for its
/// transcript, Go to End button handle and scroll view. A missing last message is
/// reported with the resting state (a viewport past the end may leave the
/// last row unrealized and off the accessibility hierarchy).
@MainActor
func openLongConversation(in app: XCUIApplication, context: String = "after opening") -> OpenConversation {
    let opened = enterLongConversation(in: app, context: context)
    XCTAssertTrue(
        opened.lastMessage.waitForExistence(timeout: Fixture.settleTimeout),
        "\(context): last transcript message never appeared — "
            + restingState(of: opened.lastMessage, named: "last assistant paragraph", in: opened)
    )
    return opened
}

/// `openLongConversation` without waiting for the last message, so a
/// test can observe the transcript's very first settled state.
@MainActor
func enterLongConversation(in app: XCUIApplication, context: String) -> OpenConversation {
    let workspaceRow = app.staticTexts[Fixture.workspaceTitle].firstMatch
    if !workspaceRow.waitForExistence(timeout: Fixture.workspaceTimeout) {
        // Same fallback as AppStoreScreenshotTests: a collapsed iPad
        // sidebar hides the workspace list behind the first nav button.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(workspaceRow.waitForExistence(timeout: Fixture.settleTimeout))
    }
    workspaceRow.tap()

    let agentRow = app.staticTexts[Fixture.agentName].firstMatch
    XCTAssertTrue(
        agentRow.waitForExistence(timeout: Fixture.settleTimeout),
        "\(context): explicit workspace entry did not show the sole agent"
    )
    agentRow.tap()

    let lastMessage = message(in: app, containing: Fixture.lastMessageFragment)
    let goToEnd = app.buttons[Fixture.goToEndIdentifier].firstMatch
    let transcript = app.scrollViews[Fixture.transcriptIdentifier].firstMatch
    XCTAssertTrue(
        transcript.waitForExistence(timeout: Fixture.elementTimeout),
        "\(context): transcript scroll view not found"
    )
    return OpenConversation(lastMessage: lastMessage, goToEnd: goToEnd, transcript: transcript)
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

/// Navigates back out of the transcript to the workspace list so the
/// next `openLongConversation` is a fresh entry; relaunches when no back
/// path leads there (a split view keeps the transcript in its detail column).
@MainActor
func leaveConversation(in app: XCUIApplication) {
    let workspaceRow = app.staticTexts[Fixture.workspaceTitle].firstMatch
    var backTapsLeft = Fixture.backNavigationAttempts
    while backTapsLeft > 0, !workspaceRow.waitForExistence(timeout: Fixture.backNavigationTimeout) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        guard back.exists else { break }
        back.tap()
        backTapsLeft -= 1
    }
    if !workspaceRow.waitForExistence(timeout: Fixture.elementTimeout) {
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
    context: String
) {
    guard waitUntilSettled(
        on: lastRow,
        named: rowName,
        in: opened,
        context: context,
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
func waitUntilSettled(
    on lastRow: XCUIElement,
    named rowName: String,
    in opened: OpenConversation,
    context: String,
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

/// True once the last forced follow has reported an outcome — not while
/// one is in flight or before the entry follow has started.
@MainActor
func followHasReported(in opened: OpenConversation) -> Bool {
    let report = followReport(in: opened)
    return report.hasPrefix(Fixture.followReportPrefix) && report != Fixture.pendingFollowReport
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
    container.frame.insetBy(dx: 0, dy: -Fixture.rePinTolerance).contains(frame)
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
// swiftlint:enable file_length
