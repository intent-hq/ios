import XCTest

/// Exercises the real navigation, observation and reconciliation path for #446.
nonisolated final class CreateWorkspaceSelectionUITests: XCTestCase {
    private static let elementTimeout: TimeInterval = 15

    @MainActor
    func testBackThenForwardPreservesProviderAndNamedModelThroughRefresh() throws {
        continueAfterFailure = false
        let gate = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-provider-\(UUID().uuidString).trigger")
        defer { try? FileManager.default.removeItem(at: gate) }
        try Data().write(to: gate)
        let app = XCUIApplication()
        app.launchArguments += ["--demo-data", "--demo-workspace-provider-trigger-file=" + gate.path]
        app.launch()
        openCreationForm(in: app)

        let provider = app.buttons["creation.providerPicker"]
        let model = app.buttons["creation.modelPicker"]
        XCTAssertTrue(provider.waitForExistence(timeout: Self.elementTimeout))
        provider.tap()
        app.buttons["Codex"].tap()
        XCTAssertTrue(model.waitForExistence(timeout: Self.elementTimeout))
        model.tap()
        app.buttons["Named Model"].tap()
        attachEvidence(in: app, name: "selected-before-back")
        assertSelections(in: app)

        app.navigationBars["Create Workspace"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Select Branch"].waitForExistence(timeout: Self.elementTimeout))
        try FileManager.default.removeItem(at: gate)
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["Loading providers..."].waitForExistence(timeout: Self.elementTimeout))
        XCTAssertFalse(provider.exists)
        XCTAssertFalse(model.exists)
        XCTAssertFalse(app.buttons["Create"].isEnabled)
        attachEvidence(in: app, name: "refresh-pending")

        try Data().write(to: gate)
        XCTAssertTrue(provider.waitForExistence(timeout: Self.elementTimeout))
        attachEvidence(in: app, name: "selected-after-refresh")
        assertSelections(in: app)
        XCTAssertTrue(app.buttons["Create"].isEnabled)
        // Never tap Create: this check only navigates and edits a draft.
    }

    @MainActor
    private func openCreationForm(in app: XCUIApplication) {
        let create = app.buttons["Create workspace"]
        XCTAssertTrue(create.waitForExistence(timeout: Self.elementTimeout))
        create.tap()
        let repository = app.staticTexts["nova-labs/console"]
        XCTAssertTrue(repository.waitForExistence(timeout: Self.elementTimeout))
        repository.tap()
        app.buttons["Next"].tap()
        XCTAssertTrue(app.navigationBars["Select Branch"].waitForExistence(timeout: Self.elementTimeout))
        let next = app.buttons["Next"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: next)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: Self.elementTimeout), .completed)
        next.tap()
    }

    @MainActor
    private func assertSelections(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["creation.providerPicker"].staticTexts["Codex"].exists)
        XCTAssertTrue(app.buttons["creation.modelPicker"].staticTexts["Named Model"].exists)
        XCTAssertTrue(app.staticTexts["Implementor"].exists, "The specialist must stay unchanged")
    }

    @MainActor
    private func attachEvidence(in app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
