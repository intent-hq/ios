import Foundation

#if DEBUG
/// Debug UI tests seed a saved pinned loopback route, then use the production
/// ConnectionManager and connecting/recovery views. Only post-admission data is
/// served by demo fixtures; no progress state or connected flag is injected.
enum DemoStartupConnection {
    private static var startupBackendID: BackendID?

    static func consumeStartupBackendID() -> BackendID? {
        defer { startupBackendID = nil }
        return startupBackendID
    }

    static var isEnabled: Bool { configuration != nil }

    private static var configuration: (port: Int, pin: String)? {
        let environment = ProcessInfo.processInfo.environment
        guard DemoMode.isEnabled,
              let rawPort = environment["INTENT_STARTUP_TEST_PORT"], let port = Int(rawPort),
              (1...Int(UInt16.max)).contains(port),
              let pin = environment["INTENT_STARTUP_TEST_PIN"], !pin.isEmpty else { return nil }
        return (port, pin)
    }

    static func seedSavedMachineIfNeeded() {
        guard let configuration else { return }
        let saved = PersistenceManager.shared.upsertConnection(StoredConnection(
            server: PairedServer(
                hosts: ["127.0.0.1"],
                port: configuration.port,
                name: "Startup Test Mac",
                pairedAt: Date(),
                certFingerprint: configuration.pin
            ),
            token: "startup-test-owner",
            displayName: "Startup Test Mac"
        ))
        PersistenceManager.shared.setActiveConnection(id: saved.id)
        startupBackendID = BackendID(saved.id)
    }
}
#else
enum DemoStartupConnection {
    static let isEnabled = false
}
#endif
