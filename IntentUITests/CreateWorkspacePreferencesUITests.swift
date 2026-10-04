import XCTest

nonisolated final class CreateWorkspacePreferencesUITests: XCTestCase {
    private static let elementTimeout: TimeInterval = 15

    @MainActor
    func testCancelledFormRemembersAgentSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "--demo-settings"]
        app.launch()
        openForm(in: app)
        app.scrollViews["creation.form"].swipeUp()
        app.buttons["creation.specialistPicker"].tap()
        app.buttons["Verifier"].tap()
        app.buttons["creation.providerPicker"].tap()
        app.buttons["Codex"].tap()
        let model = app.buttons["creation.modelPicker"]
        XCTAssertTrue(model.waitForExistence(timeout: Self.elementTimeout))
        model.tap()
        app.buttons["Named Model"].tap()
        app.buttons["creation.reasoningPicker"].tap()
        app.buttons["high"].tap()
        closeForm(in: app)

        openForm(in: app)
        app.scrollViews["creation.form"].swipeUp()
        assertValue("Verifier", for: "creation.specialistPicker", in: app)
        assertValue("Codex", for: "creation.providerPicker", in: app)
        assertValue("Named Model", for: "creation.modelPicker", in: app)
        assertValue("high", for: "creation.reasoningPicker", in: app)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "remembered-agent-settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["creation.specialistPicker"].tap()
        app.buttons["None"].tap()
        closeForm(in: app)
        openForm(in: app)
        app.scrollViews["creation.form"].swipeUp()
        assertValue("None", for: "creation.specialistPicker", in: app)
        assertValue("Codex", for: "creation.providerPicker", in: app)
        assertValue("Named Model", for: "creation.modelPicker", in: app)
        assertValue("high", for: "creation.reasoningPicker", in: app)
    }

    @MainActor
    private func closeForm(in app: XCUIApplication) {
        app.buttons["creation.back"].tap()
        app.buttons["creation.branchBack"].tap()
        app.buttons["creation.close"].tap()
        XCTAssertTrue(app.buttons["intent.menu.open"].waitForExistence(timeout: Self.elementTimeout))
    }

    @MainActor
    private func openForm(in app: XCUIApplication) {
        app.openHomeAction("workspace")
        let repository = app.buttons["creation.repository.nova-labs/console"]
        XCTAssertTrue(repository.waitForExistence(timeout: Self.elementTimeout))
        repository.tap()
        app.buttons["Next"].tap()
        let branch = app.buttons["creation.branch.main"]
        XCTAssertTrue(branch.waitForExistence(timeout: Self.elementTimeout))
        branch.tap()
        app.buttons["Next"].tap()
        XCTAssertTrue(app.buttons["creation.specialistPicker"].waitForExistence(timeout: Self.elementTimeout))
    }

    @MainActor
    private func assertValue(_ value: String, for identifier: String, in app: XCUIApplication) {
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: app.buttons[identifier])
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: Self.elementTimeout), .completed)
    }
}
