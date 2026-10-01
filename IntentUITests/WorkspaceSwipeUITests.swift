import XCTest

nonisolated final class WorkspaceSwipeUITests: XCTestCase {
    private static let timeout: TimeInterval = 15
    private static let workspaceId = "demo-ws-dashboard"

    @MainActor
    func testRightSwipeOpensRecentAgentAndBackReturnsToWorkspace() {
        let app = launchWorkspaces()
        let row = app.buttons["workspace.row.\(Self.workspaceId)"]
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 280, dy: 0)))
        let transcript = app.scrollViews["transcript.scrollView"]
        XCTAssertTrue(transcript.waitForExistence(timeout: Self.timeout))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "workspace-right-swipe-recent-agent"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        if UIDevice.current.userInterfaceIdiom == .phone {
            app.buttons["conversation.back"].tap()
        } else {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(app.buttons["Workspace actions"].waitForExistence(timeout: Self.timeout))
        XCTAssertFalse(transcript.exists)
    }

    @MainActor
    func testShortRightSwipeCancelsAndTapStillOpensOverview() {
        let app = launchWorkspaces()
        let row = app.buttons["workspace.row.\(Self.workspaceId)"]
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 60, dy: 0)))
        XCTAssertTrue(app.buttons["workspaces.search.open"].exists)
        XCTAssertFalse(app.scrollViews["transcript.scrollView"].exists)
        row.tap()
        XCTAssertTrue(app.buttons["Workspace actions"].waitForExistence(timeout: Self.timeout))
        XCTAssertFalse(app.scrollViews["transcript.scrollView"].exists)
    }

    @MainActor
    func testClosingTrailingActionsWithLongRightSwipeDoesNotOpenAgent() {
        let app = launchWorkspaces()
        let row = app.buttons["workspace.row.\(Self.workspaceId)"]
        revealActions(on: row)
        let archive = app.buttons["workspace.archive.\(Self.workspaceId)"]
        XCTAssertTrue(archive.waitForExistence(timeout: Self.timeout))
        let start = visibleRowPoint(in: app, row: row, action: archive)
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 220, dy: 0)))
        XCTAssertTrue(archive.waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["workspaces.search.open"].exists)
        XCTAssertFalse(app.scrollViews["transcript.scrollView"].exists)
    }

    @MainActor
    func testArchiveAndDeleteRequireConfirmationAndPersistAfterRefresh() {
        let app = launchWorkspaces()
        let row = app.buttons["workspace.row.\(Self.workspaceId)"]
        for action in ["Archive", "Delete"] {
            revealActions(on: row)
            let button = app.buttons["workspace.\(action.lowercased()).\(Self.workspaceId)"]
            XCTAssertTrue(button.waitForExistence(timeout: Self.timeout))
            button.tap()
            let alert = app.alerts["\(action) Workspace"]
            XCTAssertTrue(alert.waitForExistence(timeout: Self.timeout))
            XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Add usage analytics dashboard")).firstMatch.exists)
            alert.buttons["Cancel"].tap()
            XCTAssertTrue(row.exists)
        }
        revealActions(on: row)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "workspace-archive-delete-swipe"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["workspace.archive.\(Self.workspaceId)"].tap()
        app.alerts["Archive Workspace"].buttons["Archive"].tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: Self.timeout))

        let otherId = "demo-ws-flaky-tests"
        let other = app.buttons["workspace.row.\(otherId)"]
        XCTAssertTrue(other.waitForExistence(timeout: Self.timeout))
        revealActions(on: other)
        app.buttons["workspace.delete.\(otherId)"].tap()
        app.alerts["Delete Workspace"].buttons["Delete"].tap()
        XCTAssertTrue(other.waitForNonExistence(timeout: Self.timeout))
        app.scrollViews["workspaces.list"].swipeDown()
        XCTAssertFalse(row.exists)
        XCTAssertFalse(other.exists)
    }

    @MainActor
    func testGroupedAndSearchedRowsRevealActionsAndCloseWithoutNavigation() {
        let app = launchWorkspaces()
        for mode in ["Recent", "Repo", "Status"] {
            app.buttons["workspaces.viewMode.\(mode)"].tap()
            let row = app.buttons["workspace.row.\(Self.workspaceId)"]
            let visibleBottom = app.buttons["intent.menu.open"].frame.minY
            for _ in 0..<4 where row.frame.maxY > visibleBottom {
                app.scrollViews["workspaces.list"].swipeUp()
            }
            XCTAssertTrue(row.isHittable)
            revealActions(on: row)
            let archive = app.buttons["workspace.archive.\(Self.workspaceId)"]
            XCTAssertTrue(archive.waitForExistence(timeout: Self.timeout))
            visibleRowPoint(in: app, row: row, action: archive).tap()
            XCTAssertTrue(archive.waitForNonExistence(timeout: Self.timeout))
            XCTAssertTrue(app.buttons["workspaces.search.open"].exists)
        }
        app.buttons["workspaces.search.open"].tap()
        let field = app.textFields["workspaces.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: Self.timeout))
        field.typeText("usage\n")
        let row = app.buttons["workspace.row.\(Self.workspaceId)"]
        revealActions(on: row)
        let delete = app.buttons["workspace.delete.\(Self.workspaceId)"]
        XCTAssertTrue(delete.waitForExistence(timeout: Self.timeout))
        let archive = app.buttons["workspace.archive.\(Self.workspaceId)"]
        let start = visibleRowPoint(in: app, row: row, action: archive)
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 100, dy: 0)))
        XCTAssertTrue(delete.waitForNonExistence(timeout: Self.timeout))
        row.tap()
        XCTAssertTrue(app.buttons["Workspace actions"].waitForExistence(timeout: Self.timeout))
    }

    @MainActor
    func testFailedDeleteKeepsRowAndShowsError() {
        let app = launchWorkspaces(arguments: ["--demo-workspace-action-error"])
        let row = app.buttons["workspace.row.\(Self.workspaceId)"]
        revealActions(on: row)
        app.buttons["workspace.delete.\(Self.workspaceId)"].tap()
        app.alerts["Delete Workspace"].buttons["Delete"].tap()
        let error = app.alerts["Workspace action failed"]
        XCTAssertTrue(error.waitForExistence(timeout: Self.timeout))
        error.buttons["OK"].tap()
        XCTAssertTrue(row.exists)
    }

    @MainActor
    func testVerticalScrollingStillWorksWhenDraggingOnWorkspaceRows() {
        let app = launchWorkspaces(arguments: ["--demo-long-workspace-list"])
        let row = app.buttons["workspace.row.demo-ws-flaky-tests"]
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertFalse(app.staticTexts["workspaces.title"].isHittable)
        XCTAssertFalse(app.buttons["workspace.delete.\(Self.workspaceId)"].exists)
        XCTAssertTrue(app.buttons["workspaces.search.open"].exists)
    }

    @MainActor
    func testHorizontalSwipeLocksVerticalScrollingUntilFingerLifts() {
        let app = launchWorkspaces(arguments: ["--demo-long-workspace-list"])
        let row = app.buttons["workspace.row.\(Self.workspaceId)"]
        let origin = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -80)))
        XCTAssertTrue(row.isHittable)

        let archive = app.buttons["workspace.archive.\(Self.workspaceId)"]
        let verticalDrifts: [CGFloat] = [-60, 60]
        for verticalDrift in verticalDrifts {
            let startingY = row.frame.minY
            let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            let end = start.withOffset(CGVector(dx: -180, dy: verticalDrift))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
            XCTAssertTrue(archive.waitForExistence(timeout: Self.timeout))
            XCTAssertEqual(row.frame.minY, startingY, accuracy: 2)
            visibleRowPoint(in: app, row: row, action: archive).tap()
            XCTAssertTrue(archive.waitForNonExistence(timeout: Self.timeout))
        }

        let startingY = row.frame.minY
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -80)))
        XCTAssertLessThan(row.frame.minY, startingY - 20)
        XCTAssertFalse(archive.exists)
    }

    @MainActor
    func testOpeningAnotherRowClosesPreviousActions() {
        let app = launchWorkspaces()
        revealActions(on: app.buttons["workspace.row.\(Self.workspaceId)"])
        let firstAction = app.buttons["workspace.archive.\(Self.workspaceId)"]
        XCTAssertTrue(firstAction.waitForExistence(timeout: Self.timeout))
        revealActions(on: app.buttons["workspace.row.demo-ws-flaky-tests"])
        XCTAssertTrue(app.buttons["workspace.archive.demo-ws-flaky-tests"].waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(firstAction.waitForNonExistence(timeout: Self.timeout))
    }

    @MainActor
    func testShortDragsPreserveOpenOrClosedStateWithoutInvokingActions() {
        let app = launchWorkspaces()
        let row = app.buttons["workspace.row.\(Self.workspaceId)"]
        let archive = app.buttons["workspace.archive.\(Self.workspaceId)"]
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -24, dy: 0)))
        XCTAssertTrue(archive.waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["workspaces.search.open"].exists)

        revealActions(on: row)
        XCTAssertTrue(archive.waitForExistence(timeout: Self.timeout))
        let openStart = visibleRowPoint(in: app, row: row, action: archive)
        openStart.press(forDuration: 0.05, thenDragTo: openStart.withOffset(CGVector(dx: 24, dy: 0)))
        XCTAssertTrue(archive.isHittable)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        openStart.press(forDuration: 0.05, thenDragTo: openStart.withOffset(CGVector(dx: 100, dy: 0)))
        XCTAssertTrue(archive.waitForNonExistence(timeout: Self.timeout))
        row.tap()
        XCTAssertTrue(app.buttons["Workspace actions"].waitForExistence(timeout: Self.timeout))
    }

    @MainActor
    private func launchWorkspaces(arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-workspace-actions"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["workspace.row.\(Self.workspaceId)"].waitForExistence(timeout: Self.timeout))
        return app
    }

    @MainActor
    private func revealActions(on row: XCUIElement) {
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        let end = row.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func visibleRowPoint(in app: XCUIApplication, row: XCUIElement, action: XCUIElement) -> XCUICoordinate {
        let leadingEdge = max(app.frame.minX, row.frame.minX)
        return app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: (leadingEdge + action.frame.minX) / 2, dy: row.frame.midY))
    }
}
