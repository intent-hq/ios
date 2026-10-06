import XCTest

extension ConnectionLossUITests {
    private enum RecoveryFixture {
        static let timeout: TimeInterval = 15
    }

    @MainActor
    func testDifferentServerAllowsSameMachineReselection() throws {
        try assertFailureRecovery(certificateMismatch: false)
    }

    @MainActor
    func testRepairAllowsSameMachineReselection() throws {
        try assertFailureRecovery(certificateMismatch: true)
    }

    @MainActor
    private func assertFailureRecovery(certificateMismatch: Bool) throws {
        let directory = try makeTriggerDirectory()
        var arguments = ["--demo-connection-loss-pending-startup", "--demo-connection-loss-startup-failure"]
        arguments.append(certificateMismatch
            ? "--demo-connection-loss-cert-mismatch" : "--demo-connection-loss-startup-unreachable")
        arguments += ["-appThemePreference", certificateMismatch ? "dark" : "light"]
        let app = launch(directory: directory, arguments: arguments, waitForStartup: false)
        assertStartupState("connected", in: app)
        try trigger("loss", in: directory)
        let reconnect = app.buttons["connection-failure.reconnect"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: RecoveryFixture.timeout))
        XCTAssertEqual(reconnect.label, certificateMismatch ? "Re-pair Device" : "Connect to different server")
        capture(app, named: "failure-before-primary-exit")
        reconnect.tap()

        let machine = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Demo Mac")).firstMatch
        XCTAssertTrue(machine.waitForExistence(timeout: RecoveryFixture.timeout))
        XCTAssertFalse(app.buttons["connection-failure.home"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Manual Connection")).firstMatch.exists)
        XCTAssertTrue(machine.waitForExistence(timeout: RecoveryFixture.timeout), "The saved pairing must be retained")
        machine.tap()
        assertStartupState("connected", in: app)
        let back = app.buttons["connecting.home"]
        XCTAssertTrue(back.waitForExistence(timeout: RecoveryFixture.timeout), "An explicit retry must remain cancellable")
        back.tap()
        XCTAssertTrue(machine.waitForExistence(timeout: RecoveryFixture.timeout))

        try trigger("initial-data", in: directory)
        XCTAssertTrue(machine.waitForExistence(timeout: RecoveryFixture.timeout))
        XCTAssertFalse(app.buttons["intent.menu.open"].exists, "A late completion must not reopen the abandoned connection")
        XCTAssertFalse(app.buttons["connection-failure.home"].exists)
        machine.tap()
        XCTAssertTrue(app.buttons["intent.menu.open"].waitForExistence(timeout: RecoveryFixture.timeout))
        XCTAssertFalse(reconnect.exists)
        capture(app, named: "failure-primary-exit-machine-reselected")
    }
}
