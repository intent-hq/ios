import XCTest

extension XCUIApplication {
    static func intent(animations: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        if !animations {
            app.launchEnvironment["INTENT_UI_TEST_ANIMATIONS"] = "off"
        }
        return app
    }
}

extension XCUIElement {
    @discardableResult
    func appears(timeout: TimeInterval) -> Bool {
        exists || waitForExistence(timeout: timeout)
    }

    @discardableResult
    func disappears(timeout: TimeInterval) -> Bool {
        !exists || waitForNonExistence(timeout: timeout)
    }
}
