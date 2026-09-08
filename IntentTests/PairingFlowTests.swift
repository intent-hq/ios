import Foundation
import Testing
@testable import Intent

/// The QR-scan and intent://pair deep-link paths share PairingFlow: a payload
/// fingerprint is pinned directly, a fingerprint-less payload goes through
/// the cert probe + user trust confirmation, and a failed probe aborts —
/// pairing never falls back to plain ws://.
struct PairingFlowTests {

    private func makePersistence(
        storage: InMemoryKeychainStorage
    ) -> (manager: PersistenceManager, suiteName: String) {
        let suiteName = "PairingFlowTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (PersistenceManager(defaults: defaults, keychainStorage: storage), suiteName)
    }

    private func payload(fingerprint: String?) -> PairingPayload {
        PairingPayload(
            hosts: ["127.0.0.1"], port: 5181, token: "t",
            certFingerprint: fingerprint, tcAddress: nil)
    }

    @Test @MainActor func payloadFingerprintIsPinnedWithoutProbing() async {
        var probed = false
        let resolution = await PairingFlow.resolveFingerprint(
            for: payload(fingerprint: "ab:cd")
        ) { _, _ in
            probed = true
            return nil
        }
        #expect(resolution == .pinned("ab:cd"))
        #expect(!probed, "A payload fingerprint must be pinned without probing")
    }

    @Test @MainActor func fingerprintlessPayloadRequiresTrustConfirmation() async {
        let resolution = await PairingFlow.resolveFingerprint(
            for: payload(fingerprint: nil)
        ) { hosts, port in
            #expect(hosts == ["127.0.0.1"])
            #expect(port == 5181)
            return "12:34"
        }
        #expect(resolution == .needsUserConfirmation("12:34"))
    }

    @Test @MainActor func failedProbeAbortsInsteadOfConnectingUnpinned() async {
        let resolution = await PairingFlow.resolveFingerprint(
            for: payload(fingerprint: nil)
        ) { _, _ in nil }
        #expect(resolution == .failed(
            message: CertFingerprintProbe.noCertErrorMessage))
    }

    @Test @MainActor func failedNewPairSaveDisconnectsAndPublishesNoPairing() async {
        let storage = InMemoryKeychainStorage()
        let setup = makePersistence(storage: storage)
        defer { UserDefaults(suiteName: setup.suiteName)?.removePersistentDomain(forName: setup.suiteName) }
        let existing = setup.manager.upsertConnection(StoredConnection(
            server: PairedServer(
                hosts: ["10.0.0.1"], port: 4242, name: "existing", pairedAt: Date(),
                certFingerprint: "12:34"),
            token: "existing-token"))
        setup.manager.setActiveConnection(id: existing.id)
        storage.setSaveFailure(true)
        let fake = FakeConnectionManager()
        fake.responseMap["host.status"] = ["hostname": "test.local"]

        await #expect(throws: ConnectionPairing.PersistenceError.self) {
            try await PairingFlow.connect(
                payload: payload(fingerprint: "ab:cd"), certFingerprint: "ab:cd",
                connectionManager: fake, persistence: setup.manager)
        }

        #expect(setup.manager.loadConnections() == [existing])
        #expect(setup.manager.activeConnection()?.id == existing.id)
        #expect(fake.disconnectCallCount == 1)
        #expect(fake.refreshHostRoutesCallCount == 0)
    }

    @Test @MainActor func successfulPairSavePersistsAndKeepsConnectionLive() async throws {
        let storage = InMemoryKeychainStorage()
        let setup = makePersistence(storage: storage)
        defer { UserDefaults(suiteName: setup.suiteName)?.removePersistentDomain(forName: setup.suiteName) }
        let fake = FakeConnectionManager()
        fake.responseMap["host.status"] = ["hostname": "test.local"]

        let stored = try await PairingFlow.connect(
            payload: payload(fingerprint: "ab:cd"), certFingerprint: "ab:cd",
            connectionManager: fake, persistence: setup.manager)

        #expect(setup.manager.loadConnections() == [stored])
        #expect(setup.manager.activeConnection()?.id == stored.id)
        #expect(fake.disconnectCallCount == 0)
    }
}
