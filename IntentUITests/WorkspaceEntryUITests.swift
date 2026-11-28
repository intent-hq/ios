import Vision
import XCTest

nonisolated final class WorkspaceEntryUITests: XCTestCase {
    private enum Fixture {
        static let workspaceTitle = "Deflake payment integration tests"
        static let workspaceListIdentifier = "workspaces.search.open"
        static let agentName = "Test Stabilizer"
        static let overviewOnlyButton = "Context"
        static let transcriptIdentifier = "transcript.scrollView"
        static let workspaceTimeout: TimeInterval = 30
        static let elementTimeout: TimeInterval = 15
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
        let app = XCUIApplication.intent()
        app.launchArguments += ["--demo-data"]
        app.launch()
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(workspace.appears(timeout: Fixture.workspaceTimeout))
        workspace.tap()
        let agent = app.buttons["workspace.agent.demo-agent-implementor"]
        XCTAssertTrue(agent.appears(timeout: Fixture.elementTimeout))
        agent.tap()
        let back = app.buttons["conversation.back"]
        XCTAssertTrue(back.appears(timeout: Fixture.elementTimeout))

        edgeSwipe(in: app, progress: 0.15)
        XCTAssertTrue(back.exists, "A cancelled swipe must keep the conversation open")
        edgeSwipe(in: app)
        XCTAssertTrue(agent.appears(timeout: Fixture.elementTimeout))
        XCTAssertFalse(back.exists)
        edgeSwipe(in: app)
        let search = app.buttons[Fixture.workspaceListIdentifier]
        XCTAssertTrue(search.appears(timeout: Fixture.elementTimeout))

        edgeSwipe(in: app)
        let closeSwitcher = app.buttons["connection-switcher.close"]
        XCTAssertTrue(closeSwitcher.appears(timeout: Fixture.elementTimeout))
        closeSwitcher.tap()
        XCTAssertTrue(closeSwitcher.disappears(timeout: Fixture.elementTimeout))
        workspace.tap()
        XCTAssertTrue(agent.appears(timeout: Fixture.elementTimeout))
        agent.tap()
        XCTAssertTrue(back.appears(timeout: Fixture.elementTimeout))
        back.tap()
        XCTAssertTrue(agent.appears(timeout: Fixture.elementTimeout))
    }

    @MainActor
    func testSelectedPanelSurvivesCancelledSwipeAndWorkspaceReentry() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "Compact navigation gesture")
        let app = XCUIApplication.intent()
        app.launchArguments += ["--demo-data"]
        app.launch()
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        XCTAssertTrue(workspace.appears(timeout: Fixture.workspaceTimeout))
        workspace.tap()

        for title in ["Changes", "Context", "Agents"] {
            let tab = app.buttons[title].firstMatch
            XCTAssertTrue(tab.appears(timeout: Fixture.elementTimeout))
            tab.tap()
            XCTAssertTrue(tab.isSelected)

            edgeSwipe(in: app, progress: 0.15)
            XCTAssertTrue(tab.isSelected, "Cancelling navigation must retain the \(title) panel")
            edgeSwipe(in: app)
            XCTAssertTrue(app.buttons[Fixture.workspaceListIdentifier].appears(timeout: Fixture.elementTimeout))
            workspace.tap()
            XCTAssertTrue(tab.appears(timeout: Fixture.elementTimeout))
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
    private func showWorkspaceList(in app: XCUIApplication, workspaceRow: XCUIElement) {
        let workspaceList = app.buttons[Fixture.workspaceListIdentifier].firstMatch
        var backTapsLeft = Fixture.backNavigationAttempts
        while backTapsLeft > 0, !workspaceList.appears(timeout: Fixture.backNavigationTimeout) {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.exists else { break }
            back.tap()
            backTapsLeft -= 1
        }
        XCTAssertTrue(workspaceList.exists, "the workspace list never appeared")
        XCTAssertTrue(
            workspaceRow.appears(timeout: Fixture.workspaceTimeout),
            "the fixture workspace row never appeared in the workspace list"
        )
    }

    @MainActor
    func testAgentRowOpensConversationFromPreviewAndEmptySpace() {
        let app = XCUIApplication.intent()
        app.launchArguments += ["--demo-data"]
        app.launch()
        let workspace = app.staticTexts["Add usage analytics dashboard"].firstMatch
        showWorkspaceList(in: app, workspaceRow: workspace)
        workspace.tap()

        let row = app.buttons["workspace.agent.demo-agent-implementor"]
        let preview = app.staticTexts["Review CSV export"].firstMatch
        let transcript = app.scrollViews[Fixture.transcriptIdentifier].firstMatch
        for target in ["Markdown preview", "row center", "trailing space", "bottom padding"] {
            XCTAssertTrue(row.appears(timeout: Fixture.elementTimeout))
            XCTAssertTrue(preview.appears(timeout: Fixture.elementTimeout))
            let point = agentRowTapPoint(target, row: row.frame, preview: preview.frame)
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: point.x, dy: point.y))
                .tap()
            XCTAssertTrue(
                transcript.appears(timeout: Fixture.elementTimeout),
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
            XCTAssertTrue(transcript.disappears(timeout: Fixture.elementTimeout))
        }
    }

    @MainActor
    func testDelegatedAgentRowOpensConversationFromIndentation() {
        let app = XCUIApplication.intent()
        app.launchArguments += ["--demo-data"]
        app.launch()
        let workspace = app.staticTexts[Fixture.workspaceTitle].firstMatch
        showWorkspaceList(in: app, workspaceRow: workspace)
        workspace.tap()
        let delegates = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "delegated agents")).firstMatch
        XCTAssertTrue(delegates.appears(timeout: Fixture.elementTimeout))
        delegates.tap()
        let row = app.buttons["workspace.agent.demo-agent-deflake-capture"]
        XCTAssertTrue(row.appears(timeout: Fixture.elementTimeout))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 2, dy: 0))
            .tap()
        let transcript = app.scrollViews[Fixture.transcriptIdentifier].firstMatch
        XCTAssertTrue(
            transcript.appears(timeout: Fixture.elementTimeout),
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
        let app = XCUIApplication.intent()
        app.launchArguments += ["--demo-data", "--demo-design-scenario=context"]
        app.launch()
        let workspace = app.staticTexts["Build Spec Writer Page"].firstMatch
        XCTAssertTrue(workspace.appears(timeout: 30))
        workspace.tap()
        let context = app.buttons["Context"].firstMatch
        XCTAssertTrue(context.appears(timeout: 15))
        context.tap()

        let disclosure = app.buttons["Child notes for Spec"]
        let task = app.buttons["workspace.note.context-task-1"]
        XCTAssertTrue(disclosure.appears(timeout: 15))
        XCTAssertTrue(task.appears(timeout: 15))
        assertContextTreeSpacing(in: app)
        for _ in 0..<6 where !task.isHittable { app.swipeUp() }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Context with single-line and wrapped task labels"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        disclosure.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: -2))
            .tap()
        XCTAssertTrue(task.disappears(timeout: 15))
        XCTAssertEqual(disclosure.value as? String, "Collapsed")
        disclosure.tap()
        XCTAssertTrue(task.appears(timeout: 15))
        XCTAssertEqual(disclosure.value as? String, "Expanded")

        task.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: -2))
            .tap()
        let taskNavigation = app.navigationBars["Build the icon gallery interface"]
        XCTAssertTrue(taskNavigation.appears(timeout: 15))
        let noteScreenshot = XCTAttachment(screenshot: app.screenshot())
        noteScreenshot.name = "note-viewer-flat-back-button"
        noteScreenshot.lifetime = .keepAlways
        add(noteScreenshot)
        taskNavigation.buttons.element(boundBy: 0).tap()
        let spec = app.buttons["workspace.note.spec"]
        XCTAssertTrue(spec.appears(timeout: 15))
        spec.tap()
        XCTAssertTrue(app.navigationBars["Spec"].appears(timeout: 15))
    }

    @MainActor
    private func assertContextTreeSpacing(in app: XCUIApplication) {
        let spec = app.buttons["workspace.note.spec"]
        let first = app.buttons["workspace.note.context-task-0"]
        let second = app.buttons["workspace.note.context-task-1"]
        let last = app.buttons["workspace.note.context-task-2"]
        let preferences = app.buttons["workspace.note.preferences"]
        XCTAssertTrue(preferences.appears(timeout: 15))
        XCTAssertEqual(first.frame.minY - spec.frame.maxY, 16, accuracy: 1, "36pt root-to-children gap")
        XCTAssertEqual(second.frame.minY - first.frame.maxY, 4, accuracy: 1, "24pt nested row gap")
        XCTAssertEqual(last.frame.minY - second.frame.maxY, 4, accuracy: 1, "24pt nested row gap")
        XCTAssertEqual(preferences.frame.minY - last.frame.maxY, 28, accuracy: 1, "48pt root note gap")
        XCTAssertEqual(first.frame.minX - preferences.frame.minX, 48, accuracy: 1, "48pt child indentation")
    }
}
