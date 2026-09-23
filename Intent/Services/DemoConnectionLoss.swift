import Foundation

/// Opt-in UI regression seam, like the transcript fixture gates: only demo
/// mode reads trigger files. Drives the real connection publisher, never the
/// coordinator's overlay flag. A scenario runs once even after Home/reselection.
enum DemoConnectionLoss {
    private static let directoryPrefix = "--demo-connection-loss-directory="
    private static let demoPort = 443
    private static var started = false

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
            try await DemoFixtures.wait(for: .triggerFile(directory.appendingPathComponent("loss")))
            try Task.checkCancellation()
            if ProcessInfo.processInfo.arguments.contains("--demo-connection-loss-cert-mismatch"),
               let connection = connection as? ConnectionManager {
                connection.certMismatches = [HostCertMismatch(host: "demo.invalid", fingerprint: "00:11")]
            }
            connection.connectionState = ProcessInfo.processInfo.arguments.contains("--demo-connection-loss-reconnecting")
                ? .reconnecting(attempt: 1) : .disconnected
            if ProcessInfo.processInfo.arguments.contains("--demo-connection-loss-startup-failure") {
                coordinator.onConnectionFailed(error: "Server certificate has changed. Re-pair to trust the new certificate.")
                return
            }
            try await DemoFixtures.wait(for: .triggerFile(directory.appendingPathComponent("recover")))
            try Task.checkCancellation()
            connection.connectionState = .connected
        } catch {
            // Root teardown cancels the scenario; it must not revive Home.
        }
    }
}
