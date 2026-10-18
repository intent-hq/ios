import Vision
import XCTest

/// Guards intent-hq/ios#349 against the `--demo-data` fixtures: tapping a
/// workspace whose only foreground agent is a single top-level agent lands
/// on the workspace overview and stays there once the agent list has
/// loaded, after a pull-to-refresh reload, and after leaving and
/// re-entering the workspace. Only an explicit tap on the agent row opens
/// its conversation.
///
/// Runs under the `Intent` scheme (`scripts/xcodebuild.sh test-ios`, CI).
nonisolated final class WorkspaceEntryUITests: XCTestCase {
    private enum Fixture {
        /// `DemoFixtures.longConversationWorkspaceId`'s title: the fixture
        /// workspace with exactly one top-level agent (its delegates are
        /// background sub-agents).
        static let workspaceTitle = "Deflake payment integration tests"
        static let workspaceListIdentifier = "workspaces.search.open"
        /// `DemoFixtures.longConversationAgents`' top-level agent name: the
        /// agent row on the overview and, once opened, the conversation title.
        static let agentName = "Test Stabilizer"
        /// The overview's Agents/Context segmented control: present only on
        /// the workspace overview, never on a conversation.
        static let overviewOnlyButton = "Context"
        /// `ConversationTranscriptView`'s scroll view identifier.
        static let transcriptIdentifier = "transcript.scrollView"
        static let workspaceTimeout: TimeInterval = 30
        static let elementTimeout: TimeInterval = 15
        /// Long enough for the agent list to have loaded and for any
        /// forward the load could trigger to have navigated.
        static let noForwardWindow: TimeInterval = 4
        static let pollInterval: TimeInterval = 0.25
        static let backNavigationAttempts = 3
        static let backNavigationTimeout: TimeInterval = 3
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        continueAfterFailure = true
        try super.tearDownWithError()
    }

    @MainActor
    func testEdgeSwipeBackReturnsThroughWorkspaceAndCanBeCancelled() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "Compact navigation gesture")
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data"]
        app.launch()
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.workspaceTimeout))
        workspace.tap()
        let agent = app.buttons["workspace.agent.demo-agent-implementor"]
        XCTAssertTrue(agent.waitForExistence(timeout: Fixture.elementTimeout))
        agent.tap()
        let back = app.buttons["conversation.back"]
        XCTAssertTrue(back.waitForExistence(timeout: Fixture.elementTimeout))

        edgeSwipe(in: app, progress: 0.15)
        XCTAssertTrue(back.exists, "A cancelled swipe must keep the conversation open")
        edgeSwipe(in: app)
        XCTAssertTrue(agent.waitForExistence(timeout: Fixture.elementTimeout))
        XCTAssertFalse(back.exists)
        edgeSwipe(in: app)
        let search = app.buttons[Fixture.workspaceListIdentifier]
        XCTAssertTrue(search.waitForExistence(timeout: Fixture.elementTimeout))

        edgeSwipe(in: app)
        let closeSwitcher = app.buttons["connection-switcher.close"]
        XCTAssertTrue(closeSwitcher.waitForExistence(timeout: Fixture.elementTimeout))
        closeSwitcher.tap()
        XCTAssertTrue(closeSwitcher.waitForNonExistence(timeout: Fixture.elementTimeout))
        workspace.tap()
        XCTAssertTrue(agent.waitForExistence(timeout: Fixture.elementTimeout))
        agent.tap()
        XCTAssertTrue(back.waitForExistence(timeout: Fixture.elementTimeout))
        back.tap()
        XCTAssertTrue(agent.waitForExistence(timeout: Fixture.elementTimeout))
    }

    @MainActor
    func testSelectedPanelSurvivesCancelledSwipeAndWorkspaceReentry() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "Compact navigation gesture")
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data"]
        app.launch()
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.workspaceTimeout))
        workspace.tap()

        for title in ["Changes", "Context", "Agents"] {
            let tab = app.buttons[title].firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: Fixture.elementTimeout))
            tab.tap()
            XCTAssertTrue(tab.isSelected)

            edgeSwipe(in: app, progress: 0.15)
            XCTAssertTrue(tab.isSelected, "Cancelling navigation must retain the \(title) panel")
            edgeSwipe(in: app)
            XCTAssertTrue(app.buttons[Fixture.workspaceListIdentifier].waitForExistence(timeout: Fixture.elementTimeout))
            workspace.tap()
            XCTAssertTrue(tab.waitForExistence(timeout: Fixture.elementTimeout))
            XCTAssertTrue(tab.isSelected, "Re-entering the workspace must restore the \(title) panel")
        }
    }

    @MainActor
    private func edgeSwipe(in app: XCUIApplication, progress: CGFloat = 0.85) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: progress, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
    }

    @MainActor
    func testCreateNewAgentMenuOpensAgentSetup() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data"]
        if let appearance = ProcessInfo.processInfo.environment["INTENT_UITEST_APPEARANCE"] {
            app.launchArguments += ["-appThemePreference", appearance]
        }
        app.launch()
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: Fixture.workspaceTimeout))
        workspace.tap()
        let actions = app.buttons["Workspace actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: Fixture.elementTimeout))
        actions.tap()
        let createAgent = app.buttons["Create New Agent"]
        XCTAssertTrue(createAgent.waitForExistence(timeout: Fixture.elementTimeout))
        XCTAssertTrue(createAgent.isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "create-agent-menu"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        createAgent.tap()
        XCTAssertTrue(app.navigationBars["New Agent"].waitForExistence(timeout: Fixture.elementTimeout))
        let specialist = app.staticTexts["Implementor"].firstMatch
        XCTAssertTrue(specialist.waitForExistence(timeout: Fixture.elementTimeout))
        specialist.tap()
        let next = app.buttons["Next"]
        XCTAssertTrue(next.isEnabled)
        try assertToolbarLabel("Next", button: next, in: app, capture: "new-agent-next")
        next.tap()
        XCTAssertTrue(app.navigationBars["Provider & Model"].waitForExistence(timeout: Fixture.elementTimeout))
        let create = app.buttons["Create"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: create)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: Fixture.elementTimeout), .completed)
        try assertToolbarLabel("Create", button: create, in: app, capture: "new-agent-create")
        app.buttons["Back"].tap()
        app.buttons["Close"].tap()
        actions.tap()
        app.buttons["New browser"].tap()
        let address = app.textFields["Browser address"]
        XCTAssertTrue(address.waitForExistence(timeout: Fixture.elementTimeout))
        address.tap()
        address.typeText("localhost:3000")
        try assertToolbarLabel("Open", button: app.buttons["Open"], in: app, capture: "new-browser-open")
    }

    @MainActor
    private func assertToolbarLabel(
        _ label: String, button: XCUIElement, in app: XCUIApplication, capture: String
    ) throws {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = capture
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertTrue(button.isHittable)
        let image = try XCTUnwrap(button.screenshot().image.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let renderedLabels = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        XCTAssertTrue(renderedLabels.contains(label), "Expected full toolbar label \(label), rendered \(renderedLabels)")
    }

    @MainActor
    func testWorkspaceTapLandsOnOverviewAndOnlyTheAgentRowOpensTheConversation() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["INTENT_UITEST_TRANSCRIPT_CRASH_REPRO"] == "1",
            "Temporary quarantine for the unresolved app crash tracked at https://github.com/intent-hq/ios/issues/427; "
                + "opt in with TEST_RUNNER_INTENT_UITEST_TRANSCRIPT_CRASH_REPRO=1."
        )
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data"]
        app.launch()

        let workspaceRow = app.staticTexts[Fixture.workspaceTitle].firstMatch
        showWorkspaceList(in: app, workspaceRow: workspaceRow)

        // Cold entry: the agent list loads after the overview appears.
        workspaceRow.tap()
        assertOverviewStaysPut(in: app, context: "after the workspace tap")

        // Reload: pull-to-refresh re-fetches the agent list.
        let agentRow = app.staticTexts[Fixture.agentName].firstMatch
        app.scrollViews.containing(.staticText, identifier: Fixture.agentName).firstMatch.swipeDown()
        assertOverviewStaysPut(in: app, context: "after pulling to refresh the agent list")

        // Re-entry: leaving and tapping the workspace again is a fresh load.
        showWorkspaceList(in: app, workspaceRow: workspaceRow)
        workspaceRow.tap()
        assertOverviewStaysPut(in: app, context: "after re-entering the workspace")

        // Only the explicit agent tap opens the conversation.
        agentRow.tap()
        let transcript = app.scrollViews[Fixture.transcriptIdentifier].firstMatch
        XCTAssertTrue(
            transcript.waitForExistence(timeout: Fixture.elementTimeout),
            "tapping the agent row on the overview must open its conversation"
        )
    }

    /// Waits for the overview and its loaded agent list, then asserts that
    /// no transcript appears for `Fixture.noForwardWindow`.
    @MainActor
    private func assertOverviewStaysPut(in app: XCUIApplication, context: String) {
        let overviewOnly = app.buttons[Fixture.overviewOnlyButton].firstMatch
        let agentRow = app.staticTexts[Fixture.agentName].firstMatch
        let transcript = app.scrollViews[Fixture.transcriptIdentifier].firstMatch
        XCTAssertTrue(
            overviewOnly.waitForExistence(timeout: Fixture.elementTimeout),
            "\(context): the workspace overview never appeared"
        )
        XCTAssertTrue(
            agentRow.waitForExistence(timeout: Fixture.elementTimeout),
            "\(context): the agent list never loaded on the overview"
        )

        let deadline = Date().addingTimeInterval(Fixture.noForwardWindow)
        while Date() < deadline {
            XCTAssertFalse(
                transcript.exists,
                "\(context): the workspace forwarded into its sole agent's conversation"
            )
            RunLoop.current.run(until: Date().addingTimeInterval(Fixture.pollInterval))
        }
        XCTAssertTrue(overviewOnly.exists, "\(context): the workspace overview was left")
    }

    /// Navigates back until the workspace list's search button shows,
    /// then waits for `workspaceRow` in it; on a collapsed iPad sidebar the
    /// first nav button reveals the list. Gating on the row's text alone
    /// would stop on the overview, whose navigation title is the same text.
    @MainActor
    private func showWorkspaceList(in app: XCUIApplication, workspaceRow: XCUIElement) {
        let workspaceList = app.buttons[Fixture.workspaceListIdentifier].firstMatch
        var backTapsLeft = Fixture.backNavigationAttempts
        while backTapsLeft > 0, !workspaceList.waitForExistence(timeout: Fixture.backNavigationTimeout) {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.exists else { break }
            back.tap()
            backTapsLeft -= 1
        }
        XCTAssertTrue(workspaceList.exists, "the workspace list never appeared")
        XCTAssertTrue(
            workspaceRow.waitForExistence(timeout: Fixture.workspaceTimeout),
            "the fixture workspace row never appeared in the workspace list"
        )
    }

    @MainActor
    func testAgentRowOpensConversationFromPreviewAndEmptySpace() {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data"]
        app.launch()
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        showWorkspaceList(in: app, workspaceRow: workspace)
        workspace.tap()

        let row = app.buttons["workspace.agent.demo-agent-implementor"]
        let preview = app.staticTexts["Review CSV export"].firstMatch
        let transcript = app.scrollViews[Fixture.transcriptIdentifier].firstMatch
        for target in ["Markdown preview", "row center", "trailing space", "bottom padding"] {
            XCTAssertTrue(row.waitForExistence(timeout: Fixture.elementTimeout))
            XCTAssertTrue(preview.waitForExistence(timeout: Fixture.elementTimeout))
            let point = agentRowTapPoint(target, row: row.frame, preview: preview.frame)
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: point.x, dy: point.y))
                .tap()
            XCTAssertTrue(
                transcript.waitForExistence(timeout: Fixture.elementTimeout),
                "Tapping \(target) must open the agent conversation"
            )
            if UIDevice.current.userInterfaceIdiom == .phone {
                XCTAssertTrue(app.staticTexts["Dashboard Implementor, Agent"].exists)
                app.buttons["conversation.back"].tap()
            } else {
                XCTAssertTrue(app.navigationBars["Dashboard Implementor"].exists)
                let agentsBack = app.navigationBars.buttons["Agents"].firstMatch
                if agentsBack.exists {
                    agentsBack.tap()
                } else {
                    app.navigationBars.buttons.element(boundBy: 0).tap()
                }
            }
            XCTAssertTrue(transcript.waitForNonExistence(timeout: Fixture.elementTimeout))
        }
    }

    @MainActor
    func testDelegatedAgentRowOpensConversationFromIndentation() {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data"]
        app.launch()
        let workspace = app.staticTexts[Fixture.workspaceTitle].firstMatch
        showWorkspaceList(in: app, workspaceRow: workspace)
        workspace.tap()
        let delegates = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "delegated agents")).firstMatch
        XCTAssertTrue(delegates.waitForExistence(timeout: Fixture.elementTimeout))
        delegates.tap()
        let row = app.buttons["workspace.agent.demo-agent-deflake-capture"]
        XCTAssertTrue(row.waitForExistence(timeout: Fixture.elementTimeout))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 2, dy: 0))
            .tap()
        let transcript = app.scrollViews[Fixture.transcriptIdentifier].firstMatch
        XCTAssertTrue(
            transcript.waitForExistence(timeout: Fixture.elementTimeout),
            "Tapping the empty indentation must open the delegated agent conversation"
        )
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertTrue(app.staticTexts["Capture Race Fixer, Agent"].exists)
        } else {
            XCTAssertTrue(app.navigationBars["Capture Race Fixer"].exists)
        }
    }

    private func agentRowTapPoint(_ target: String, row: CGRect, preview: CGRect) -> CGPoint {
        switch target {
        case "Markdown preview": CGPoint(x: preview.midX, y: preview.midY)
        case "row center": CGPoint(x: row.midX, y: row.midY)
        case "trailing space": CGPoint(x: row.maxX - 2, y: preview.midY)
        default: CGPoint(x: row.midX, y: row.maxY - 2)
        }
    }
}

extension WorkspaceEntryUITests {
    @MainActor
    func testDisclosureAndNoteNavigationKeepSeparateTouchTargets() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-design-scenario=context"]
        app.launch()
        let workspace = app.staticTexts["Build Spec Writer Page"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 30))
        workspace.tap()
        let context = app.buttons["Context"].firstMatch
        XCTAssertTrue(context.waitForExistence(timeout: 15))
        context.tap()

        let disclosure = app.buttons["Child notes for Spec"]
        let task = app.buttons["workspace.note.context-task-1"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 15))
        XCTAssertTrue(task.waitForExistence(timeout: 15))
        assertContextTreeSpacing(in: app)
        for _ in 0..<6 where !task.isHittable { app.swipeUp() }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Context with single-line and wrapped task labels"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        disclosure.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: -2))
            .tap()
        XCTAssertTrue(task.waitForNonExistence(timeout: 15))
        XCTAssertEqual(disclosure.value as? String, "Collapsed")
        disclosure.tap()
        XCTAssertTrue(task.waitForExistence(timeout: 15))
        XCTAssertEqual(disclosure.value as? String, "Expanded")

        task.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: -2))
            .tap()
        let taskNavigation = app.navigationBars["Build the icon gallery interface"]
        XCTAssertTrue(taskNavigation.waitForExistence(timeout: 15))
        let noteScreenshot = XCTAttachment(screenshot: app.screenshot())
        noteScreenshot.name = "note-viewer-flat-back-button"
        noteScreenshot.lifetime = .keepAlways
        add(noteScreenshot)
        taskNavigation.buttons.element(boundBy: 0).tap()
        let spec = app.buttons["workspace.note.spec"]
        XCTAssertTrue(spec.waitForExistence(timeout: 15))
        spec.tap()
        XCTAssertTrue(app.navigationBars["Spec"].waitForExistence(timeout: 15))
    }

    @MainActor
    private func assertContextTreeSpacing(in app: XCUIApplication) {
        let spec = app.buttons["workspace.note.spec"]
        let first = app.buttons["workspace.note.context-task-0"]
        let second = app.buttons["workspace.note.context-task-1"]
        let last = app.buttons["workspace.note.context-task-2"]
        let preferences = app.buttons["workspace.note.preferences"]
        XCTAssertTrue(preferences.waitForExistence(timeout: 15))
        // Buttons extend 10pt above/below their visible rows for a full touch target.
        XCTAssertEqual(first.frame.minY - spec.frame.maxY, 16, accuracy: 1, "36pt root-to-children gap")
        XCTAssertEqual(second.frame.minY - first.frame.maxY, 4, accuracy: 1, "24pt nested row gap")
        XCTAssertEqual(last.frame.minY - second.frame.maxY, 4, accuracy: 1, "24pt nested row gap")
        XCTAssertEqual(preferences.frame.minY - last.frame.maxY, 28, accuracy: 1, "48pt root note gap")
        XCTAssertEqual(first.frame.minX - preferences.frame.minX, 48, accuracy: 1, "48pt child indentation")
    }
}
