import Foundation
@testable import Intent
import Testing

@Suite("Ephemeral persistence (--demo-data)", .serialized)
struct EphemeralPersistenceTests {
    private func connection() -> StoredConnection {
        StoredConnection(
            server: PairedServer(
                hosts: ["10.0.0.1"],
                port: 4242,
                name: "daemon",
                pairedAt: Date(),
                certFingerprint: "aa:bb"
            ),
            token: "tok",
            displayName: "Demo"
        )
    }

    @Test func startsUnpairedAndForgetsStateAcrossInstances() {
        let first = PersistenceManager.ephemeral()
        #expect(first.loadConnections().isEmpty)
        #expect(first.lastUsedConnection() == nil)

        let stored = first.upsertConnection(connection())
        first.setActiveConnection(id: stored.id)
        first.saveLastScreen(
            PersistenceManager.SavedScreen(
                screen: "workspaceDetail",
                workspaceId: "ws-demo",
                agentId: nil,
                agentName: nil,
                noteId: nil,
                noteTitle: nil
            ),
            for: stored.id
        )
        #expect(first.lastUsedConnection()?.id == stored.id)

        // A relaunch builds a new ephemeral manager: nothing carries over.
        let second = PersistenceManager.ephemeral()
        #expect(second.loadConnections().isEmpty)
        #expect(second.lastUsedConnection() == nil)
        #expect(second.loadLastScreen(for: stored.id) == nil)
    }

    @Test func doesNotTouchTheStandardDefaults() {
        let ephemeral = PersistenceManager.ephemeral()
        #expect(ephemeral.defaults !== UserDefaults.standard)
        #expect(ephemeral.backendPublisher == nil)
    }
}
