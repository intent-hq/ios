import XCTest

nonisolated final class WorkspaceAgentGroupsUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        continueAfterFailure = true
        try super.tearDownWithError()
    }

    @MainActor
    func testLargeWorkspaceStaysResponsiveWhileExpandingAndScrolling() {
        let app = launch(scenario: "agent-groups-large")
        let children = app.buttons["workspace.agents.children.groups-parent"]
        XCTAssertTrue(app.buttons["workspace.agent.large-parent-0000"].exists)
        capture(app, name: "Large workspace with 1200 top-level agents")
        children.tap()
        let firstChild = app.buttons["workspace.agent.large-child-0000"]
        XCTAssertTrue(firstChild.waitForExistence(timeout: 15))
        app.swipeUp()
        app.swipeUp()
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace.agent.large-child-")).firstMatch.exists)
        capture(app, name: "Large delegated group after scrolling")
        app.swipeDown()
        app.swipeDown()
        for _ in 0..<4 where !children.isHittable { app.swipeDown() }
        XCTAssertTrue(children.isHittable)
        children.tap()
        XCTAssertEqual(children.value as? String, "Collapsed")
        XCTAssertTrue(app.buttons["workspace.agent.large-parent-0000"].waitForExistence(timeout: 15))
    }

    @MainActor
    func testSectionsLoadOnExpansionAndKeepNestedChildrenWithTheirParent() {
        let app = launch(scenario: "agent-groups")
        for id in ["child", "grandchild", "background", "orphan", "retired"] {
            XCTAssertFalse(app.buttons["workspace.agent.groups-" + id].exists)
        }
        capture(app, name: "Agent groups collapsed with counts")

        let children = app.buttons["workspace.agents.children.groups-parent"]
        XCTAssertEqual(children.value as? String, "Collapsed")
        children.tap()
        XCTAssertTrue(app.buttons["workspace.agent.groups-child"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["workspace.agent.groups-grandchild"].exists)
        let nested = reveal(app, id: "workspace.agents.children.groups-child")
        nested.tap()
        XCTAssertTrue(app.buttons["workspace.agent.groups-grandchild"].waitForExistence(timeout: 15))
        capture(app, name: "Nested delegated children expanded")
        reveal(app, id: "workspace.agents.children.groups-parent").tap()
        XCTAssertTrue(app.buttons["workspace.agent.groups-child"].waitForNonExistence(timeout: 15))
        XCTAssertFalse(app.buttons["workspace.agent.groups-grandchild"].exists)

        // Rebuilding the parent's rows must preserve its nested expansion state.
        reveal(app, id: "workspace.agents.children.groups-parent").tap()
        XCTAssertTrue(app.buttons["workspace.agent.groups-child"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["workspace.agent.groups-grandchild"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["workspace.agents.children.groups-child"].value as? String, "Expanded")
        reveal(app, id: "workspace.agents.children.groups-parent").tap()
        XCTAssertTrue(app.buttons["workspace.agent.groups-grandchild"].waitForNonExistence(timeout: 15))

        reveal(app, id: "workspace.agents.background").tap()
        XCTAssertTrue(app.buttons["workspace.agent.groups-background"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["workspace.agent.groups-background-child"].exists)
        reveal(app, id: "workspace.agents.children.groups-background").tap()
        XCTAssertTrue(app.buttons["workspace.agent.groups-background-child"].waitForExistence(timeout: 15))
        capture(app, name: "Background parent and its delegated child")
        reveal(app, id: "workspace.agents.background").tap()
        XCTAssertTrue(app.buttons["workspace.agent.groups-background-child"].waitForNonExistence(timeout: 15))

        reveal(app, id: "workspace.agents.delegated").tap()
        XCTAssertTrue(app.buttons["workspace.agent.groups-orphan"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["workspace.agent.groups-retired-child"].exists)
        XCTAssertFalse(app.buttons["workspace.agent.groups-background-child"].exists)
        reveal(app, id: "workspace.agents.children.groups-orphan").tap()
        XCTAssertTrue(app.buttons["workspace.agent.groups-orphan-child"].waitForExistence(timeout: 15))
        capture(app, name: "Orphan parent retains its nested child")
        reveal(app, id: "workspace.agents.delegated").tap()
        reveal(app, id: "workspace.agents.retired").tap()
        XCTAssertTrue(app.buttons["workspace.agent.groups-retired"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["workspace.agent.groups-retired-child"].exists)
        capture(app, name: "Retired section expanded")
        reveal(app, id: "workspace.agents.retired").tap()
        XCTAssertTrue(app.buttons["workspace.agent.groups-retired"].waitForNonExistence(timeout: 15))
    }

    @MainActor
    func testLoadingFailureCanRetryOnlyTheExpandedSection() throws {
        let gate = FileManager.default.temporaryDirectory.appendingPathComponent("agent-groups-\(UUID().uuidString).trigger")
        defer { try? FileManager.default.removeItem(at: gate) }
        let app = launch(scenario: "agent-groups-retry", arguments: ["--demo-agent-group-trigger-file=" + gate.path])
        let background = reveal(app, id: "workspace.agents.background")
        background.tap()
        XCTAssertTrue(app.descendants(matching: .any)["workspace.agents.background.loading"].firstMatch.waitForExistence(timeout: 15))
        capture(app, name: "Background group loading")
        try Data().write(to: gate)
        let retry = app.buttons["workspace.agents.background.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["workspace.agent.groups-background"].exists)
        capture(app, name: "Background group failure with retry")
        retry.tap()
        XCTAssertTrue(app.buttons["workspace.agent.groups-background"].waitForExistence(timeout: 15))
        XCTAssertFalse(retry.exists)
        XCTAssertFalse(app.buttons["workspace.agent.groups-child"].exists)
        XCTAssertFalse(app.buttons["workspace.agent.groups-orphan"].exists)
        XCTAssertFalse(app.buttons["workspace.agent.groups-retired"].exists)
    }

    @MainActor
    private func launch(scenario: String, arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-design-scenario=" + scenario] + arguments
        app.launch()
        let workspace = app.staticTexts["Workspace agent design"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 30))
        workspace.tap()
        XCTAssertTrue(app.buttons["workspace.agent.groups-parent"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    private func reveal(_ app: XCUIApplication, id: String) -> XCUIElement {
        let element = app.buttons[id]
        if element.isHittable { return element }
        for _ in 0..<4 {
            app.swipeDown()
            if element.isHittable { return element }
        }
        for _ in 0..<8 {
            app.swipeUp()
            if element.isHittable { return element }
        }
        XCTAssertTrue(element.waitForExistence(timeout: 15))
        XCTAssertTrue(element.isHittable)
        return element
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "agent-group-evidence-" + name + ".png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
