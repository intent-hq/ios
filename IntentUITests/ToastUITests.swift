import XCTest

nonisolated final class ToastUITests: XCTestCase {
    private static let timeout: TimeInterval = 30
    private static let maximumWidth: CGFloat = 560

    @MainActor
    func testCompletionToastInBothThemes() {
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        defer { XCUIDevice.shared.orientation = .portrait }
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["--demo-data", "--demo-toast", "-appThemePreference", appearance]
            app.launch()
            let toast = app.buttons["Add usage analytics dashboard: Dashboard Implementor completed"]
            XCTAssertTrue(toast.waitForExistence(timeout: Self.timeout))
            XCTAssertLessThanOrEqual(toast.frame.width, Self.maximumWidth, "Wide windows cap the toast width")
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "toast-\(appearance)"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }
}
