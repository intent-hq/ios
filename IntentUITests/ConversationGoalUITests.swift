import XCTest

nonisolated final class ConversationGoalUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

    @MainActor
    func testGoalStripExpandsEditsRemovesAndFollowsGoalCommands() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            open(app, appearance: appearance)
            verifyStrip(in: app, appearance: appearance)
            verifyEditing(in: app, appearance: appearance)
            verifyRemoveAndCommand(in: app, appearance: appearance)
            app.terminate()
        }
    }

    @MainActor
    private func open(_ app: XCUIApplication, appearance: String) {
        app.launchArguments = [
            "--demo-data", "--demo-design-scenario=goal", "-appThemePreference", appearance,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launch()
        let workspace = app.buttons["workspace.row.demo-ws-agent-design"]
        XCTAssertTrue(workspace.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        workspace.tap()
        let agent = app.buttons["workspace.agent.demo-agent-design"]
        XCTAssertTrue(agent.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
        agent.tap()
        XCTAssertTrue(app.textViews["composer.textView"].waitForExistence(timeout: Self.timeout))
    }

    @MainActor
    private func verifyStrip(in app: XCUIApplication, appearance: String) {
        let text = app.descendants(matching: .any)["goalStrip.text"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: Self.timeout), app.debugDescription)
        XCTAssertTrue(text.label.hasPrefix("Goal: Finish the release acceptance checks."), "Strip label: \(text.label)")
        let notice = app.descendants(matching: .any)["goalNotice"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: Self.timeout), "The goal_command row renders as a goal notice")
        XCTAssertTrue(notice.label.hasPrefix("Goal set: Finish the release"), "Notice label: \(notice.label)")
        capture(app, name: "Goal strip collapsed \(appearance)")

        let toggle = app.buttons["goalStrip.toggle"]
        XCTAssertEqual(toggle.value as? String, "Collapsed")
        XCTAssertEqual(toggle.label, "Show the full goal")
        toggle.tap()
        XCTAssertTrue(waitForValue(toggle, "Expanded"), "The toggle reports the expanded state")
        XCTAssertTrue(
            app.links.matching(NSPredicate(format: "label CONTAINS %@", "github.com")).firstMatch.waitForExistence(timeout: Self.timeout),
            "The expanded goal shows its URL as a link\n\(app.debugDescription)"
        )
        capture(app, name: "Goal strip expanded \(appearance)")
        toggle.tap()
        XCTAssertTrue(waitForValue(toggle, "Collapsed"), "The toggle collapses the goal again")
    }

    @MainActor
    private func verifyEditing(in app: XCUIApplication, appearance: String) {
        let text = app.descendants(matching: .any)["goalStrip.text"].firstMatch
        XCTAssertEqual(app.buttons["goalStrip.edit"].label, "Edit goal")
        app.buttons["goalStrip.edit"].tap()
        let editor = app.textViews["goalEditor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: Self.timeout))
        XCTAssertEqual((editor.value as? String)?.hasPrefix("Finish the release"), true, "The editor is pre-filled")
        capture(app, name: "Goal editor \(appearance)")
        app.buttons["goalEditor.cancel"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(text.label.hasPrefix("Goal: Finish the release"), "Cancel keeps the goal")

        app.buttons["goalStrip.edit"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Self.timeout), "The editor focuses its text")
        let prefilled = editor.value as? String ?? ""
        editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: prefilled.count))
        editor.typeText("Ship the beta build")
        app.buttons["goalEditor.save"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: Self.timeout))
        XCTAssertTrue(
            text.wait(for: \.label, toEqual: "Goal: Ship the beta build", timeout: Self.timeout),
            "Saving updates the strip: \(text.label)"
        )
    }

    @MainActor
    private func verifyRemoveAndCommand(in app: XCUIApplication, appearance: String) {
        let text = app.descendants(matching: .any)["goalStrip.text"].firstMatch
        XCTAssertEqual(app.buttons["goalStrip.remove"].label, "Remove goal")
        app.buttons["goalStrip.remove"].tap()
        XCTAssertTrue(text.waitForNonExistence(timeout: Self.timeout), "Remove hides the strip")
        let removed = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Goal removed.")).firstMatch
        XCTAssertTrue(removed.waitForExistence(timeout: Self.timeout), "Removing posts a goal notice")

        let composer = app.textViews["composer.textView"]
        composer.tap()
        composer.typeText("/goal Rehearse the rollback")
        app.buttons["composer.send"].tap()
        XCTAssertTrue(text.waitForExistence(timeout: Self.timeout), "A /goal send sets the goal")
        XCTAssertEqual(text.label, "Goal: Rehearse the rollback")
        XCTAssertTrue(waitForValue(composer, ""), "The composer clears after the command succeeds")
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label == %@", "/goal Rehearse the rollback")).firstMatch.exists,
            "A /goal command leaves no user bubble"
        )
        capture(app, name: "Goal strip after command \(appearance)")
    }

    @MainActor
    private func waitForValue(_ element: XCUIElement, _ value: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: Self.timeout) == .completed
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
