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
    func testCreateNewAgentMenuOpensAgentSetup() {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data"]
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
        createAgent.tap()
        XCTAssertTrue(app.navigationBars["New Agent"].waitForExistence(timeout: Fixture.elementTimeout))
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
}
