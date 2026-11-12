import XCTest

/// The usage-limit turn failure from `--demo-design-scenario=turn-failure`
/// must read as a friendly card, keeping the raw JSON-RPC reason behind a
/// collapsed Details disclosure with Copy, in both appearances.
nonisolated final class TurnFailureNoticeUITests: XCTestCase {
    private static let timeout: TimeInterval = 15

    @MainActor
    func testUsageLimitCardHidesRawDetailsUntilExpanded() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            open(app, appearance: appearance)
            verifyCard(in: app, appearance: appearance)
            app.terminate()
        }
    }

    @MainActor
    private func open(_ app: XCUIApplication, appearance: String) {
        app.launchArguments = [
            "--demo-data", "--demo-design-scenario=turn-failure", "-appThemePreference", appearance,
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
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: Self.timeout))
    }

    @MainActor
    private func verifyCard(in app: XCUIApplication, appearance: String) {
        let title = app.staticTexts["Usage limit reached"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: Self.timeout), app.debugDescription)
        let message = app.descendants(matching: .any)["turnFailure.message"].firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: Self.timeout), app.debugDescription)
        XCTAssertTrue(message.label.contains("You've hit your usage limit."), "Message label: \(message.label)")
        XCTAssertTrue(message.label.contains("try again at Nov 14th, 2026 8:07 AM"), "Message label: \(message.label)")
        for marker in ["codexErrorInfo", "JSON-RPC", "internal error"] {
            XCTAssertFalse(message.label.contains(marker), "The friendly message must not show \(marker)")
        }
        XCTAssertFalse(
            app.descendants(matching: .any)["turnFailure.retryHint"].exists,
            "The retry hint is hidden when the message already says it"
        )
        XCTAssertFalse(app.descendants(matching: .any)["turnFailure.link"].exists, "An inline URL needs no separate link row")
        XCTAssertTrue(inlineLink(in: app).exists, "The URL in the message is an accessible link\n\(app.debugDescription)")

        let details = app.buttons["turnFailure.details"]
        XCTAssertTrue(details.waitForExistence(timeout: Self.timeout))
        XCTAssertEqual(details.value as? String, "Collapsed", "Details start collapsed")
        let raw = app.descendants(matching: .any)["turnFailure.rawDetails"]
        XCTAssertFalse(raw.exists, "Raw JSON stays hidden until Details is expanded")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "codexErrorInfo")).firstMatch.exists)
        capture(app, name: "Turn failure collapsed \(appearance)")

        XCTAssertTrue(details.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout), app.debugDescription)
        details.tap()
        XCTAssertTrue(raw.waitForExistence(timeout: Self.timeout), "Expanding Details shows the raw reason")
        XCTAssertEqual(details.value as? String, "Expanded")
        XCTAssertTrue(raw.label.contains(#""codexErrorInfo":"usageLimitExceeded""#), "Raw label: \(raw.label)")
        let copy = app.buttons["turnFailure.copy"]
        XCTAssertTrue(copy.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout), app.debugDescription)
        capture(app, name: "Turn failure expanded \(appearance)")

        copy.tap()
        XCTAssertTrue(
            copy.wait(for: \.label, toEqual: "Copied", timeout: Self.timeout),
            "Copy confirms the raw reason reached the pasteboard"
        )
        details.tap()
        XCTAssertTrue(raw.waitForNonExistence(timeout: Self.timeout), "Collapsing hides the raw reason again")

        // The row's Copy overlay must not swallow the inline link tap.
        let link = inlineLink(in: app)
        XCTAssertTrue(link.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout), app.debugDescription)
        link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: Self.timeout), "Tapping the inline link opens the URL")
        safari.terminate()
    }

    @MainActor
    private func inlineLink(in app: XCUIApplication) -> XCUIElement {
        app.links.matching(NSPredicate(format: "label CONTAINS %@", "chatgpt.com/settings/usage")).firstMatch
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
