import Foundation

/// Saved-machine fixtures for Settings screenshots and interaction tests.
/// Only the existing ephemeral demo store is written; normal launch is untouched.
enum DemoSettings {
    private static let port = 5181
    private static var startupBackendID: BackendID?

    static func seedConnectionsIfNeeded() {
        guard DemoMode.isEnabled, ProcessInfo.processInfo.arguments.contains("--demo-settings") else { return }
        let persistence = PersistenceManager.shared
        let primary = persistence.upsertConnection(connection(name: "Studio Mac", host: "studio.invalid"))
        persistence.upsertConnection(connection(name: "Travel Mac", host: "travel.invalid"))
        persistence.setActiveConnection(id: primary.id)
        startupBackendID = BackendID(primary.id)
    }

    /// Native scene restoration outlives the ephemeral demo records. Consume
    /// the seeded primary only on the first actual window appearance so later
    /// foregrounding and newly opened Travel windows keep their own selection.
    static func consumeStartupBackendID() -> BackendID? {
        defer { startupBackendID = nil }
        return startupBackendID
    }

    private static func connection(name: String, host: String) -> StoredConnection {
        StoredConnection(
            server: PairedServer(hosts: [host], port: port, name: name, pairedAt: Date()),
            token: UUID().uuidString,
            displayName: name
        )
    }
}
