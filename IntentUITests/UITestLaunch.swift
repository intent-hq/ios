import XCTest

extension XCUIApplication {
    static func intent(animations: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        if !animations {
            app.launchEnvironment["INTENT_UI_TEST_ANIMATIONS"] = "off"
        }
        return app
    }
}

private enum Settle {
    static let pollInterval: TimeInterval = 0.1
    static let maximumWait: TimeInterval = 2
}

extension XCUIElement {
    @discardableResult
    func appears(timeout: TimeInterval) -> Bool {
        guard exists || waitForExistence(timeout: timeout) else { return false }
        let probe = firstMatch
        var previous = probe.frame
        let deadline = Date().addingTimeInterval(min(timeout, Settle.maximumWait))
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(Settle.pollInterval))
            let current = probe.frame
            if current == previous { break }
            previous = current
        }
        return true
    }

    @discardableResult
    func disappears(timeout: TimeInterval) -> Bool {
        !exists || waitForNonExistence(timeout: timeout)
    }
}
