import XCTest

private typealias LossFixture = ConnectionLossUITestFixture

/// Controls on the iPad shell during a drop.
extension ConnectionLossUITests {
    @MainActor
    func testIPadControlInventoryDuringDrop() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad rail and Assistant sidebar")
        let directory = try makeTriggerDirectory()
        let app = launch(directory: directory, arguments: ["--demo-connection-loss-reconnecting"])
        try trigger("loss", in: directory)
        assertBanner(in: app)
        XCTAssertFalse(app.buttons["ipad.rail.createWorkspace"].isEnabled, "New workspace needs the Mac")
        for section in ["assistant", "workspaces", "pullRequests", "connections", "settings"] {
            XCTAssertTrue(app.buttons["ipad.rail.\(section)"].isEnabled, "Navigation stays on: \(section) (R1.13)")
        }
        XCTAssertTrue(app.buttons["ipad.rail.appearance"].isEnabled, "Appearance is local")
        app.buttons["ipad.rail.assistant"].tap()
        let create = app.buttons["assistant.sidebar.newConversation"]
        XCTAssertTrue(create.waitForExistence(timeout: LossFixture.timeout), "The Assistant opens from the last confirmed owner")
        XCTAssertFalse(create.isEnabled, "A new Assistant conversation needs the Mac")
        capture(app, named: "ipad-read-only-assistant")
    }
}
