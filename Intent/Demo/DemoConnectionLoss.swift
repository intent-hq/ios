#if DEBUG
import Foundation
import SwiftUI

enum DemoConnectionLoss {
    private static let directoryPrefix = "--demo-connection-loss-directory="
    private static let demoPort = 443
    private static var started = false
    private static var backgroundLossStarted = false
    private static let quickRecoveryMilliseconds = 250
    private static let statePollMilliseconds = 10

    private static var backgroundScenario: String? {
        guard directory != nil else { return nil }
        return LaunchOptions.current.arguments.first { $0.hasPrefix("--demo-background-loss=") }
            .map { String($0.dropFirst("--demo-background-loss=".count)) }
    }

    static func record(_ event: String) {
        guard let directory else { return }
        try? Data().write(to: directory.appendingPathComponent(event))
    }

    static func sceneChanged(_ phase: ScenePhase, connection: any SessionConnectionManaging) {
        guard let scenario = backgroundScenario else { return }
        if phase == .background, !backgroundLossStarted {
            backgroundLossStarted = true
            if scenario != "activation-quick" { connection.connectionState = .reconnecting(attempt: 1) }
            record("did-background")
        } else if phase == .active, backgroundLossStarted {
            if scenario == "activation-quick" { connection.connectionState = .reconnecting(attempt: 1) }
            record("did-activate")
        }
    }

    static let networkAvailability: NetworkAvailability? = {
        guard let directory else { return nil }
        return NetworkAvailability { DemoNetworkPathMonitor(directory: directory) }
    }()

    private static var directory: URL? {
        guard DemoMode.isEnabled,
              let argument = LaunchOptions.current.arguments.last(where: { $0.hasPrefix(directoryPrefix) }),
              !argument.dropFirst(directoryPrefix.count).isEmpty else { return nil }
        return URL(fileURLWithPath: String(argument.dropFirst(directoryPrefix.count)))
    }

    static var initialDataGate: DemoFixtures.ResponseGate? {
        guard let directory,
              LaunchOptions.current.contains("--demo-connection-loss-pending-startup") else { return nil }
        return .triggerFile(directory.appendingPathComponent("initial-data"))
    }

    static var initialRoutingGate: DemoFixtures.ResponseGate? {
        guard let directory, initialDataGate != nil else { return nil }
        if LaunchOptions.current.contains("--demo-connection-loss-startup-timeout") {
            return .triggerFile(directory.appendingPathComponent("initial-timeout"))
        }
        return initialDataGate
    }

    static func conversationLoadGate(for method: String) -> DemoFixtures.ResponseGate? {
        guard let directory, ["agent.get", "chat.subscribe", "note.list", "note.get"].contains(method),
              LaunchOptions.current.contains("--demo-connection-loss-hold-conversations"),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("loss").path) else { return nil }
        return .triggerFile(directory.appendingPathComponent("conversation-data"))
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
            if LaunchOptions.current.contains("--demo-connection-loss-cert-mismatch"),
               let connection = connection as? ConnectionManager {
                connection.certMismatches = [HostCertMismatch(host: "demo.invalid", fingerprint: "00:11")]
            }
            if LaunchOptions.current.contains("--demo-connection-loss-stopped"),
               let connection = connection as? ConnectionManager {
                connection.reconnectStopReason = ConnectionPrincipal.AdmissionError.personChanged.localizedDescription
            }
            if let manager = connection as? ConnectionManager {
                manager.lastConnectedPrincipal = manager.currentPrincipal
            }
            DemoConnectionTransport.isDropped = true
            connection.connectionState = LaunchOptions.current.contains("--demo-connection-loss-reconnecting")
                ? .reconnecting(attempt: 1) : .disconnected
            if LaunchOptions.current.contains("--demo-connection-loss-startup-failure") {
                let message = LaunchOptions.current.contains("--demo-connection-loss-startup-unreachable")
                    ? "The saved machine could not be reached."
                    : "Server certificate has changed. Re-pair to trust the new certificate."
                coordinator.onConnectionFailed(error: message)
                return
            }
            try await DemoFixtures.wait(for: .triggerFile(directory.appendingPathComponent("recover")))
            try Task.checkCancellation()
            DemoConnectionTransport.isDropped = false
            connection.connectionState = .connected
        } catch {
        }
    }

    private static func runBackgroundScenario(
        _ scenario: String, directory: URL, connection: any SessionConnectionManaging, coordinator: AppCoordinator
    ) async throws {
        try await DemoFixtures.wait(for: .triggerFile(directory.appendingPathComponent("did-activate")))
        if scenario == "sustained" {
            try await DemoFixtures.wait(for: .triggerFile(directory.appendingPathComponent("recover")))
        } else {
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
#endif
