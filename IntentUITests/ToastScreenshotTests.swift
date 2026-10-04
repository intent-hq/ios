import XCTest

nonisolated final class ToastScreenshotTests: XCTestCase {
    private static let timeout: TimeInterval = 30

    @MainActor
    func testBeforeLight() {
        capture(before: true, appearance: "light")
    }

    @MainActor
    func testAfterLight() {
        capture(before: false, appearance: "light")
    }

    @MainActor
    func testBeforeDark() {
        capture(before: true, appearance: "dark")
    }

    @MainActor
    func testAfterDark() {
        capture(before: false, appearance: "dark")
    }

    @MainActor
    private func capture(before: Bool, appearance: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data", "--demo-toast-evidence", "-appThemePreference", appearance]
        if before { app.launchArguments.append("--toast-before") }
        app.launch()
        XCTAssertTrue(app.buttons["intent.menu.open"].waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["toast.evidence"].waitForExistence(timeout: Self.timeout))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "toast-\(before ? "before" : "after")-\(appearance)"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }
}
