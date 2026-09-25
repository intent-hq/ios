import Foundation

/// Saved-machine fixtures for Settings screenshots and interaction tests.
/// Only the existing ephemeral demo store is written; normal launch is untouched.
enum DemoSettings {
    private static let port = 5180

    static func seedConnectionsIfNeeded() {
        guard DemoMode.isEnabled, ProcessInfo.processInfo.arguments.contains("--demo-settings") else { return }
        let persistence = PersistenceManager.shared
        let primary = persistence.upsertConnection(connection(name: "Studio Mac", host: "studio.invalid"))
        persistence.upsertConnection(connection(name: "Travel Mac", host: "travel.invalid"))
        persistence.setActiveConnection(id: primary.id)
    }

    private static func connection(name: String, host: String) -> StoredConnection {
        StoredConnection(
            server: PairedServer(hosts: [host], port: port, name: name, pairedAt: Date()),
            token: UUID().uuidString,
            displayName: name
        )
    }
}
