import Foundation
@testable import Intent
import Testing

/// Tests for the connection display-name selection from a `host.status` result:
/// prettyHostname > hostname > nil (caller falls back to host:port).
struct ConnectionPairingTests {
    private func makePersistence(
        storage: InMemoryKeychainStorage
    ) throws -> (manager: PersistenceManager, suiteName: String) {
        let suiteName = "ConnectionPairingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (PersistenceManager(defaults: defaults, keychainStorage: storage), suiteName)
    }

    @Test func prefersPrettyHostnameOverHostname() {
        let status: [String: Any] = [
            "prettyHostname": "Clement's Mac Studio",
            "hostname": "ClementacStudio.local-domain"
        ]
        #expect(ConnectionPairing.displayName(fromHostStatus: status) == "Clement's Mac Studio")
    }

    @Test func fallsBackToHostnameWhenPrettyHostnameAbsent() {
        let status: [String: Any] = ["hostname": "studio.local"]
        #expect(ConnectionPairing.displayName(fromHostStatus: status) == "studio.local")
    }

    @Test func fallsBackToHostnameWhenPrettyHostnameEmpty() {
        let status: [String: Any] = ["prettyHostname": "", "hostname": "studio.local"]
        #expect(ConnectionPairing.displayName(fromHostStatus: status) == "studio.local")
    }

    @Test func returnsNilWhenBothAbsent() {
        #expect(ConnectionPairing.displayName(fromHostStatus: [String: Any]()) == nil)
    }

    @Test func returnsNilWhenBothEmpty() {
        let status: [String: Any] = ["prettyHostname": "", "hostname": ""]
        #expect(ConnectionPairing.displayName(fromHostStatus: status) == nil)
    }

    @Test func returnsNilForNonDictionaryResult() {
        #expect(ConnectionPairing.displayName(fromHostStatus: "not a dict") == nil)
    }

    @Test func fallsBackToHostnameWhenPrettyHostnameWhitespaceOnly() {
        let status: [String: Any] = ["prettyHostname": "  \n", "hostname": "studio.local"]
        #expect(ConnectionPairing.displayName(fromHostStatus: status) == "studio.local")
    }

    @Test func trimsSurroundingWhitespace() {
        let status: [String: Any] = ["prettyHostname": " Clement's Mac Studio \n"]
        #expect(ConnectionPairing.displayName(fromHostStatus: status) == "Clement's Mac Studio")
    }

    @Test func nilSelectionFallsBackToHostPortInStoredConnection() {
        let server = PairedServer(
            hosts: ["10.0.0.1"],
            port: 4242,
            name: "Intent",
            pairedAt: Date()
        )
        let stored = StoredConnection(server: server, token: "tok", displayName: nil)
        #expect(stored.displayName == "10.0.0.1:4242")
    }

    @Test @MainActor func failedRepairKeepsOldRecordAndActivePointer() async throws {
        let storage = InMemoryKeychainStorage()
        let setup = try makePersistence(storage: storage)
        defer { UserDefaults(suiteName: setup.suiteName)?.removePersistentDomain(forName: setup.suiteName) }
        let old = setup.manager.upsertConnection(StoredConnection(
            server: PairedServer(
                hosts: ["10.0.0.1"],
                port: 4242,
                name: "daemon",
                pairedAt: Date(),
                certFingerprint: "aa:bb"
            ),
            token: "old-token"
        ))
        setup.manager.setActiveConnection(id: old.id)
        storage.setSaveFailure(true)
        let fake = FakeConnectionManager()
        fake.responseMap["host.status"] = ["prettyHostname": "Updated Name"]
        try await fake.connect(hosts: ["10.0.0.1"], port: 4242, token: "new-token", certFingerprint: "aa:bb", tcAddress: nil)
        let repairedServer = PairedServer(
            hosts: ["10.0.0.1"],
            port: 4242,
            name: "daemon",
            pairedAt: Date(),
            certFingerprint: "aa:bb"
        )

        await #expect(throws: ConnectionPairing.PersistenceError.self) {
            try await ConnectionPairing.finalize(
                server: repairedServer,
                token: "new-token",
                connection: fake,
                persistence: setup.manager
            )
        }

        #expect(setup.manager.loadConnections() == [old])
        #expect(setup.manager.activeConnection()?.id == old.id)
        #expect(fake.refreshHostRoutesCallCount == 0)
    }

    /// A pairing over an undecodable saved-connections blob must not replace
    /// it with a one-entry list; it fails with a distinct, recoverable error
    /// and leaves the blob and active pointer alone (intent-hq/ios#265).
    @Test @MainActor func pairingOverUndecodableRegistryPreservesBlob() async throws {
        let storage = InMemoryKeychainStorage()
        let setup = try makePersistence(storage: storage)
        defer { UserDefaults(suiteName: setup.suiteName)?.removePersistentDomain(forName: setup.suiteName) }
        let manager = setup.manager
        let undecodable = Data("{\"v\": 99, \"schema\": \"future\"}".utf8)
        #expect(manager.saveDataToKeychain(
            data: undecodable,
            account: manager.keychainAccountConnections
        ))
        let fake = FakeConnectionManager()
        fake.responseMap["host.status"] = ["prettyHostname": "New Mac"]
        try await fake.connect(hosts: ["10.0.0.1"], port: 4242, token: "new-token", certFingerprint: "aa:bb", tcAddress: nil)
        let server = PairedServer(
            hosts: ["10.0.0.1"],
            port: 4242,
            name: "daemon",
            pairedAt: Date(),
            certFingerprint: "aa:bb"
        )

        await #expect(throws: ConnectionPairing.PersistenceError.registryUndecodable) {
            try await ConnectionPairing.finalize(
                server: server,
                token: "new-token",
                connection: fake,
                persistence: manager
            )
        }

        #expect(manager.loadDataFromKeychain(
            account: manager.keychainAccountConnections
        ) == undecodable)
        #expect(manager.isConnectionRegistryUndecodable())
        #expect(manager.activeConnection() == nil)
        #expect(manager.defaults.string(forKey: manager.activeConnectionIdKey) == nil)
        #expect(fake.refreshHostRoutesCallCount == 0)
    }
}
