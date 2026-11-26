import XCTest

nonisolated final class ConversationInlineVisualUITests: XCTestCase {
    private static let timeout: TimeInterval = 20
    private static let minimumRenderedHeight: CGFloat = 120
    private static let thumbOffset: CGFloat = 0.28
    private static let dragEndOffset: CGFloat = 1.2
    private static let dragHold: TimeInterval = 0.1

    @MainActor
    func testInlineVisualRendersInteractiveHTMLInBothAppearances() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = [
                "--demo-data", "--demo-design-scenario=inline-visual", "-appThemePreference", appearance,
                "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
            ]
            app.launch()
            let workspace = app.buttons["workspace.row.demo-ws-agent-design"]
            XCTAssertTrue(workspace.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
            workspace.tap()
            let agent = app.buttons["workspace.agent.demo-agent-design"]
            XCTAssertTrue(agent.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
            agent.tap()

            let webView = app.webViews["inlineVisual"].firstMatch
            XCTAssertTrue(webView.waitForExistence(timeout: Self.timeout))
            let goToEnd = app.buttons["transcript.goToEnd"].firstMatch
            if goToEnd.exists { goToEnd.tap() }
            let initial = webView.staticTexts["12 libraries"].firstMatch
            XCTAssertTrue(initial.waitForExistence(timeout: Self.timeout), "The visual's script must run")
            XCTAssertTrue(webView.wait(for: \.isHittable, toEqual: true, timeout: Self.timeout))
            XCTAssertGreaterThan(webView.frame.height, Self.minimumRenderedHeight)
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "<style>")).firstMatch.exists)
            capture(app, name: "inline-visual-\(appearance)")

            let slider = webView.sliders.firstMatch
            XCTAssertTrue(slider.waitForExistence(timeout: Self.timeout))
            slider.coordinate(withNormalizedOffset: CGVector(dx: Self.thumbOffset, dy: 0.5)).press(
                forDuration: Self.dragHold,
                thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: Self.dragEndOffset, dy: 0.5))
            )
            XCTAssertTrue(webView.staticTexts["40 libraries"].firstMatch.waitForExistence(timeout: Self.timeout))
            capture(app, name: "inline-visual-\(appearance)-after-slider")
            app.terminate()
        }
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
