import XCTest

nonisolated final class ConversationGoalUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

    @MainActor
    func testGoalPillEditsRemovesAndFollowsGoalCommands() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication.intent()
            open(app, appearance: appearance)
            verifyPill(in: app, appearance: appearance)
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
        XCTAssertTrue(workspace.appears(timeout: Self.timeout), app.debugDescription)
        let workspaces = app.buttons["ipad.rail.workspaces"]
        if workspaces.exists {
            XCTAssertTrue(workspaces.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
            if !workspaces.isSelected { workspaces.tap() }
            XCTAssertTrue(workspaces.wait(for: \.isSelected, toEqual: true, timeout: Self.timeout))
        }
        let agent = app.buttons["workspace.agent.demo-agent-design"]
        if !(agent.exists && agent.isHittable) {
            let expand = app.buttons["ipad.sidebar.expand"]
            if expand.exists, !workspace.isHittable { expand.tap() }
            XCTAssertTrue(workspace.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout), app.debugDescription)
            workspace.tap()
        }
        XCTAssertTrue(agent.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout), app.debugDescription)
        agent.tap()
        XCTAssertTrue(app.textViews["composer.textView"].appears(timeout: Self.timeout))
    }

    @MainActor
    private func verifyPill(in app: XCUIApplication, appearance: String) {
        let pill = app.buttons["goalPill"]
        XCTAssertTrue(pill.appears(timeout: Self.timeout), app.debugDescription)
        XCTAssertTrue(pill.label.hasPrefix("Goal: Finish the release acceptance checks."), "Pill label: \(pill.label)")
        let composer = app.textViews["composer.textView"]
        XCTAssertLessThan(pill.frame.maxY, composer.frame.minY, "The goal pill sits above the composer")
        let notice = app.descendants(matching: .any)["goalNotice"].firstMatch
        XCTAssertTrue(notice.appears(timeout: Self.timeout), "The goal_command row renders as a goal notice")
        XCTAssertTrue(notice.label.hasPrefix("Goal set: Finish the release"), "Notice label: \(notice.label)")
        capture(app, name: "Goal pill \(appearance)")
    }

    @MainActor
    private func verifyEditing(in app: XCUIApplication, appearance: String) {
        let pill = app.buttons["goalPill"]
        pill.tap()
        let editor = app.textViews["goalEditor.text"]
        XCTAssertTrue(editor.appears(timeout: Self.timeout), "Tapping the pill opens the editor")
        XCTAssertEqual((editor.value as? String)?.hasPrefix("Finish the release"), true, "The editor is pre-filled")
        XCTAssertTrue(app.staticTexts["goalEditor.count"].exists, "The editor shows a character count")
        capture(app, name: "Goal editor \(appearance)")
        app.buttons["goalEditor.cancel"].tap()
        XCTAssertTrue(editor.disappears(timeout: Self.timeout))
        XCTAssertTrue(pill.label.hasPrefix("Goal: Finish the release"), "Cancel keeps the goal")

        pill.press(forDuration: 1)
        let menuEdit = app.buttons["Edit goal"]
        XCTAssertTrue(menuEdit.appears(timeout: Self.timeout), "Long-pressing the pill offers Edit")
        XCTAssertTrue(app.buttons["Remove goal"].exists, "Long-pressing the pill offers Remove")
        capture(app, name: "Goal pill menu \(appearance)")
        menuEdit.tap()
        XCTAssertTrue(editor.appears(timeout: Self.timeout))
        XCTAssertTrue(app.keyboards.firstMatch.appears(timeout: Self.timeout), "The editor focuses its text")
        let prefilled = editor.value as? String ?? ""
        editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: prefilled.count))
        editor.typeText("Ship the beta build")
        app.buttons["goalEditor.save"].tap()
        XCTAssertTrue(editor.disappears(timeout: Self.timeout))
        XCTAssertTrue(
            pill.wait(for: \.label, toEqual: "Goal: Ship the beta build", timeout: Self.timeout),
            "Saving updates the pill: \(pill.label)"
        )
    }

    @MainActor
    private func verifyRemoveAndCommand(in app: XCUIApplication, appearance: String) {
        let pill = app.buttons["goalPill"]
        pill.press(forDuration: 1)
        let menuRemove = app.buttons["Remove goal"]
        XCTAssertTrue(menuRemove.appears(timeout: Self.timeout))
        menuRemove.tap()
        XCTAssertTrue(pill.disappears(timeout: Self.timeout), "Remove hides the pill")
        let removed = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Goal removed.")).firstMatch
        XCTAssertTrue(removed.appears(timeout: Self.timeout), "Removing posts a goal notice")

        let composer = app.textViews["composer.textView"]
        composer.tap()
        composer.typeText("/")
        let goalChip = app.buttons["composer.command.goal"]
        XCTAssertTrue(goalChip.appears(timeout: Self.timeout), "The slash chips offer the built-in /goal")
        XCTAssertEqual(goalChip.label, "/goal, built-in command")
        let firstSkill = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "composer.skill.")).firstMatch
        if firstSkill.appears(timeout: Self.timeout) {
            XCTAssertLessThan(goalChip.frame.minX, firstSkill.frame.minX, "The built-in is listed before skills")
        }
        capture(app, name: "Goal command chip \(appearance)")
        goalChip.tap()
        XCTAssertTrue(waitForValue(composer, "/goal "), "Tapping the chip inserts /goal")
        composer.typeText("Rehearse the rollback")
        app.buttons["composer.send"].tap()
        XCTAssertTrue(pill.appears(timeout: Self.timeout), "A /goal send sets the goal")
        XCTAssertEqual(pill.label, "Goal: Rehearse the rollback")
        XCTAssertTrue(waitForValue(composer, ""), "The composer clears after the command succeeds")
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label == %@", "/goal Rehearse the rollback")).firstMatch.exists,
            "A /goal command leaves no user bubble"
        )
        capture(app, name: "Goal pill after command \(appearance)")
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
