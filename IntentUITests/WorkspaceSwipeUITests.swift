import XCTest

nonisolated final class WorkspaceSwipeUITests: XCTestCase {
    private static let timeout: TimeInterval = 15
    private static let workspaceId = "demo-ws-dashboard"

    @MainActor
    func testArchiveAndDeleteRequireConfirmationAndPersistAfterRefresh() {
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        defer { if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .portrait } }
        let app = launchWorkspaces()
        let row = app.buttons["workspace.row.\(Self.workspaceId)"]
        if UIDevice.current.userInterfaceIdiom == .pad {
            app.buttons["workspace.row.demo-ws-flaky-tests"].tap()
            XCTAssertTrue(app.buttons["workspace.agent.demo-agent-deflake"].appears(timeout: Self.timeout))
        }
        XCTAssertTrue(row.label.contains("Updated "))
        verifyActionCancellation(in: app, row: row)
        revealActions(on: row)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "workspace-archive-delete-swipe"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["workspace.archive.\(Self.workspaceId)"].tap()
        app.alerts["Archive Workspace"].buttons["Archive"].tap()
        XCTAssertTrue(row.disappears(timeout: Self.timeout))
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(app.buttons["workspace.agent.demo-agent-deflake"].exists)
        }

        let otherId = "demo-ws-flaky-tests"
        let other = app.buttons["workspace.row.\(otherId)"]
        XCTAssertTrue(other.appears(timeout: Self.timeout))
        revealActions(on: other)
        app.buttons["workspace.delete.\(otherId)"].tap()
        app.alerts["Delete Workspace"].buttons["Delete"].tap()
        XCTAssertTrue(other.disappears(timeout: Self.timeout))
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(app.buttons["workspace.agent.demo-agent-deflake"].disappears(timeout: Self.timeout))
        }
        workspaceList(in: app).swipeDown()
        XCTAssertFalse(row.exists)
        XCTAssertFalse(other.exists)
        verifyArchivedWorkspace(in: app, row: row, deleted: other)
    }

    @MainActor
    private func verifyArchivedWorkspace(in app: XCUIApplication, row: XCUIElement, deleted: XCUIElement) {
        app.buttons["workspaces.menu"].tap()
        app.buttons["Show archived"].tap()
        XCTAssertTrue(row.appears(timeout: Self.timeout))
        XCTAssertTrue(row.label.contains("Archived"))
        XCTAssertFalse(row.label.contains("Updated "))
        XCTAssertFalse(deleted.exists)
        workspaceList(in: app).swipeDown()
        XCTAssertTrue(row.exists)
        XCTAssertTrue(row.label.contains("Archived"))
        XCTAssertFalse(row.label.contains("Updated "))
        let archivedScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        archivedScreenshot.name = "workspace-archived-badge"
        archivedScreenshot.lifetime = .keepAlways
        add(archivedScreenshot)
        app.buttons["workspaces.menu"].tap()
        app.buttons["Hide archived"].tap()
        XCTAssertTrue(row.disappears(timeout: Self.timeout))
    }

    @MainActor
    private func verifyActionCancellation(in app: XCUIApplication, row: XCUIElement) {
        for action in ["Archive", "Delete"] {
            revealActions(on: row)
            let button = app.buttons["workspace.\(action.lowercased()).\(Self.workspaceId)"]
            XCTAssertTrue(button.appears(timeout: Self.timeout))
            button.tap()
            let alert = app.alerts["\(action) Workspace"]
            XCTAssertTrue(alert.appears(timeout: Self.timeout))
            XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Add usage analytics dashboard")).firstMatch.exists)
            alert.buttons["Cancel"].tap()
            XCTAssertTrue(row.exists)
        }
    }

    @MainActor
    func testFailedDeleteKeepsRowAndShowsError() {
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        defer { if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .portrait } }
        let app = launchWorkspaces(arguments: ["--demo-workspace-action-error"])
        let row = app.buttons["workspace.row.\(Self.workspaceId)"]
        let other = app.buttons["workspace.row.demo-ws-flaky-tests"]
        if UIDevice.current.userInterfaceIdiom == .pad {
            other.tap()
            XCTAssertTrue(app.buttons["workspace.agent.demo-agent-deflake"].appears(timeout: Self.timeout))
        }
        revealActions(on: row)
        app.buttons["workspace.delete.\(Self.workspaceId)"].tap()
        let confirmation = app.alerts["Delete Workspace"]
        XCTAssertTrue(confirmation.appears(timeout: Self.timeout))
        XCTAssertTrue(confirmation.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Add usage analytics dashboard")).firstMatch.exists)
        confirmation.buttons["Delete"].tap()
        let error = app.alerts["Workspace action failed"]
        XCTAssertTrue(error.appears(timeout: Self.timeout))
        error.buttons["OK"].tap()
        XCTAssertTrue(row.exists)
        XCTAssertTrue(other.exists)
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(app.buttons["workspace.agent.demo-agent-deflake"].exists)
        }
    }

    @MainActor
    func testHorizontalSwipeLocksVerticalScrollingUntilFingerLifts() {
        let app = launchWorkspaces(arguments: ["--demo-long-workspace-list"])
        let workspaceId = "demo-ws-flaky-tests"
        let row = app.buttons["workspace.row.\(workspaceId)"]
        XCTAssertTrue(row.appears(timeout: Self.timeout))
        let origin = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -80)))
        XCTAssertTrue(row.isHittable)

        let archive = app.buttons["workspace.archive.\(workspaceId)"]
        let search = app.buttons["workspaces.search.open"]
        let verticalDrifts: [CGFloat] = [-60, 60]
        for verticalDrift in verticalDrifts {
            XCTAssertGreaterThan(row.frame.minY, search.frame.maxY, "The swipe row must remain below the pinned controls")
            let startingY = row.frame.minY
            let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            let end = start.withOffset(CGVector(dx: -180, dy: verticalDrift))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
            XCTAssertTrue(archive.appears(timeout: Self.timeout))
            XCTAssertEqual(row.frame.minY, startingY, accuracy: 2)
            visibleRowPoint(in: app, row: row, action: archive).tap()
            XCTAssertTrue(archive.disappears(timeout: Self.timeout))
        }

        let startingY = row.frame.minY
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -80)))
        XCTAssertLessThan(row.frame.minY, startingY - 20)
        XCTAssertFalse(archive.exists)
    }

    @MainActor
    func testShortDragsPreserveOpenOrClosedStateWithoutInvokingActions() {
        let app = launchWorkspaces()
        let row = app.buttons["workspace.row.\(Self.workspaceId)"]
        let archive = app.buttons["workspace.archive.\(Self.workspaceId)"]
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -24, dy: 0)))
        XCTAssertTrue(archive.disappears(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["workspaces.search.open"].exists)

        revealActions(on: row)
        XCTAssertTrue(archive.appears(timeout: Self.timeout))
        let openStart = visibleRowPoint(in: app, row: row, action: archive)
        openStart.press(forDuration: 0.05, thenDragTo: openStart.withOffset(CGVector(dx: 24, dy: 0)))
        XCTAssertTrue(archive.isHittable)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        openStart.press(forDuration: 0.05, thenDragTo: openStart.withOffset(CGVector(dx: 100, dy: 0)))
        XCTAssertTrue(archive.disappears(timeout: Self.timeout))
        row.tap()
        XCTAssertTrue(app.buttons["Workspace actions"].appears(timeout: Self.timeout))
    }
}

private extension WorkspaceSwipeUITests {
    @MainActor
    func launchWorkspaces(arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication.intent()
        app.launchArguments += ["--demo-data", "--demo-workspace-actions"] + arguments
        app.launch()
        let row = app.buttons["workspace.row.\(Self.workspaceId)"]
        if UIDevice.current.userInterfaceIdiom == .pad, !row.appears(timeout: 2) {
            revealSidebarIfNeeded(in: app)
        }
        XCTAssertTrue(row.appears(timeout: Self.timeout))
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(row.isHittable)
            row.tap()
            XCTAssertTrue(app.buttons["Workspace actions"].appears(timeout: Self.timeout))
            revealSidebarIfNeeded(in: app)
            XCTAssertTrue(row.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        }
        return app
    }

    @MainActor
    func revealSidebarIfNeeded(in app: XCUIApplication) {
        let expand = app.buttons["ipad.sidebar.expand"]
        if expand.exists { expand.tap() }
    }

    @MainActor
    func workspaceList(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["workspaces.list"].firstMatch
    }

    @MainActor
    func revealActions(on row: XCUIElement) {
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        let end = row.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    func visibleRowPoint(in app: XCUIApplication, row: XCUIElement, action: XCUIElement) -> XCUICoordinate {
        let leadingEdge = max(app.frame.minX, row.frame.minX)
        return app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: (leadingEdge + action.frame.minX) / 2, dy: row.frame.midY))
    }
}
