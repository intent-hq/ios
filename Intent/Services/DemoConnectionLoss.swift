import Foundation
import SwiftUI

/// Opt-in UI regression seam, like the transcript fixture gates: only demo
/// mode reads trigger files. Drives the real connection publisher, never the
/// coordinator's overlay flag. A scenario runs once even after Home/reselection.
enum DemoConnectionLoss {
    private static let directoryPrefix = "--demo-connection-loss-directory="
    private static let demoPort = 443
    private static var started = false
    private static var backgroundLossStarted = false
    private static let quickRecoveryMilliseconds = 250
    private static let statePollMilliseconds = 10
    private static let maximumTraceEntries = 256
    private static var lifecycleTrace: [String] = []

    private static var backgroundScenario: String? {
        guard directory != nil else { return nil }
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--demo-background-loss=") }
            .map { String($0.dropFirst("--demo-background-loss=".count)) }
    }

    /// Persistent evidence catches even one-frame presentations that XCUITest
    /// misses while activate() waits for the application to settle.
    static func record(_ event: String) {
        guard let directory else { return }
        try? Data().write(to: directory.appendingPathComponent(event))
        trace(event)
    }

    static func trace(_ event: @autoclosure () -> String) {
        guard let directory, lifecycleTrace.count < maximumTraceEntries else { return }
        let event = event()
        guard lifecycleTrace.last != event else { return }
        lifecycleTrace.append(event)
        let text = lifecycleTrace.enumerated().map { "\($0.offset + 1) \($0.element)" }.joined(separator: "\n")
        try? text.write(to: directory.appendingPathComponent("lifecycle-trace.txt"), atomically: true, encoding: .utf8)
    }

    static func sceneChanged(_ phase: ScenePhase, connection: any SessionConnectionManaging) {
        trace("scene=\(phase) connection=\(connection.connectionState)")
        guard let scenario = backgroundScenario else { return }
        if phase == .background, !backgroundLossStarted {
            backgroundLossStarted = true
            if scenario != "activation-quick" { connection.connectionState = .disconnected }
            record("did-background")
        } else if phase == .active, backgroundLossStarted {
            if scenario == "activation-quick" { connection.connectionState = .reconnecting(attempt: 1) }
            record("did-activate")
        }
    }

    /// Independent injected monitor, shared by demo scenes just like the live owner.
    static let networkAvailability: NetworkAvailability? = {
        guard let directory else { return nil }
        return NetworkAvailability { DemoNetworkPathMonitor(directory: directory) }
    }()

    private static var directory: URL? {
        guard DemoMode.isEnabled,
              let argument = ProcessInfo.processInfo.arguments.last(where: { $0.hasPrefix(directoryPrefix) }),
              !argument.dropFirst(directoryPrefix.count).isEmpty else { return nil }
        return URL(fileURLWithPath: String(argument.dropFirst(directoryPrefix.count)))
    }

    /// Hold fixture data independently from the optional startup timeout trigger.
    static var initialDataGate: DemoFixtures.ResponseGate? {
        guard let directory,
              ProcessInfo.processInfo.arguments.contains("--demo-connection-loss-pending-startup") else { return nil }
        return .triggerFile(directory.appendingPathComponent("initial-data"))
    }

    static var initialRoutingGate: DemoFixtures.ResponseGate? {
        guard let directory, initialDataGate != nil else { return nil }
        if ProcessInfo.processInfo.arguments.contains("--demo-connection-loss-startup-timeout") {
            return .triggerFile(directory.appendingPathComponent("initial-timeout"))
        }
        return initialDataGate
    }

    static func seedSavedMachineIfNeeded() {
        guard directory != nil else { return }
        let connection = PersistenceManager.shared.upsertConnection(StoredConnection(
            server: PairedServer(
                hosts: ["demo.invalid"],
                port: demoPort,
                name: "Demo Mac",
                pairedAt: Date(),
                certFingerprint: "00:11"
            ),
            token: UUID().uuidString,
            displayName: "Demo Mac"
        ))
        PersistenceManager.shared.setActiveConnection(id: connection.id)
    }

    static func run(connection: any SessionConnectionManaging, coordinator: AppCoordinator) async {
        guard let directory, !started else { return }
        started = true
        do {
            if let scenario = backgroundScenario {
                try await runBackgroundScenario(scenario, directory: directory, connection: connection, coordinator: coordinator)
                return
            }
            try await DemoFixtures.wait(for: .triggerFile(directory.appendingPathComponent("loss")))
            try Task.checkCancellation()
            if ProcessInfo.processInfo.arguments.contains("--demo-connection-loss-cert-mismatch"),
               let connection = connection as? ConnectionManager {
                connection.certMismatches = [HostCertMismatch(host: "demo.invalid", fingerprint: "00:11")]
            }
            connection.connectionState = ProcessInfo.processInfo.arguments.contains("--demo-connection-loss-reconnecting")
                ? .reconnecting(attempt: 1) : .disconnected
            trace("fixture-loss-delivered")
            if ProcessInfo.processInfo.arguments.contains("--demo-connection-loss-startup-failure") {
                coordinator.onConnectionFailed(error: "Server certificate has changed. Re-pair to trust the new certificate.")
                return
            }
            try await DemoFixtures.wait(for: .triggerFile(directory.appendingPathComponent("recover")))
            try Task.checkCancellation()
            trace("fixture-recovery-delivered")
            connection.connectionState = .connected
        } catch {
            // Root teardown cancels the scenario; it must not revive Home.
        }
    }

    private static func runBackgroundScenario(
        _ scenario: String, directory: URL, connection: any SessionConnectionManaging, coordinator: AppCoordinator
    ) async throws {
        try await DemoFixtures.wait(for: .triggerFile(directory.appendingPathComponent("did-activate")))
        if scenario == "sustained" {
            try await DemoFixtures.wait(for: .triggerFile(directory.appendingPathComponent("recover")))
        } else {
            // Deliberately span rendering frames, but recover within production
            // grace. Tests synchronize on evidence, never on guessed sleeps.
            try await Task.sleep(for: .milliseconds(quickRecoveryMilliseconds))
        }
        try Task.checkCancellation()
        connection.connectionState = .connected
        while coordinator.isDisconnected {
            try await Task.sleep(for: .milliseconds(statePollMilliseconds))
        }
        record("did-recover")
    }
}
