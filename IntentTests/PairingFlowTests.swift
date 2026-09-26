import Foundation
@testable import Intent
import Testing

/// The QR-scan and intent://pair deep-link paths share PairingFlow: a payload
/// fingerprint is pinned directly, a fingerprint-less payload goes through
/// the cert probe + user trust confirmation, and a failed probe aborts —
/// pairing never falls back to plain ws://.
struct PairingFlowTests {
    private func makePersistence(
        storage: InMemoryKeychainStorage
    ) -> (manager: PersistenceManager, suiteName: String) {
        let suiteName = "PairingFlowTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create test defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return (PersistenceManager(defaults: defaults, keychainStorage: storage), suiteName)
    }

    private func payload(fingerprint: String?) -> PairingPayload {
        PairingPayload(
            hosts: ["127.0.0.1"],
            port: 5181,
            token: "t",
            certFingerprint: fingerprint,
            tcAddress: nil
        )
    }

    @Test @MainActor func payloadFingerprintIsPinnedWithoutProbing() async {
        var probed = false
        let resolution = await PairingFlow.resolveFingerprint(
            for: payload(fingerprint: "ab:cd")
        ) { _, _ in
            probed = true
            return .noCertificate
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
            return .fingerprint("12:34")
        }
        #expect(resolution == .needsUserConfirmation("12:34"))
    }

    @Test @MainActor func failedProbeAbortsInsteadOfConnectingUnpinned() async {
        let resolution = await PairingFlow.resolveFingerprint(
            for: payload(fingerprint: nil)
        ) { _, _ in .noCertificate }
        #expect(resolution == .failed(
            message: CertFingerprintProbe.ProbeResult.noCertificate.abortMessage
        ))
    }

    /// The probe's failure stage (unreachable / timeout / TLS) reaches the
    /// QR and deep-link error surface instead of a generic message (ios#233).
    @Test @MainActor func failedProbeSurfacesTheFailureStage() async {
        let refused = CertFingerprintProbe.ProbeResult.unreachable(
            cause: .init(domain: .posix, code: POSIXErrorCode.ECONNREFUSED.rawValue)
        )
        let unreachable = await PairingFlow.resolveFingerprint(
            for: payload(fingerprint: nil)
        ) { _, _ in refused }
        #expect(unreachable == .failed(message: refused.abortMessage))

        let timedOut = await PairingFlow.resolveFingerprint(
            for: payload(fingerprint: nil)
        ) { _, _ in .timeout }
        #expect(timedOut == .failed(message: CertFingerprintProbe.ProbeResult.timeout.abortMessage))
        #expect(timedOut != unreachable)
    }

    @Test @MainActor func failedNewPairSaveDisconnectsAndPublishesNoPairing() async {
        let storage = InMemoryKeychainStorage()
        let setup = makePersistence(storage: storage)
        defer { UserDefaults(suiteName: setup.suiteName)?.removePersistentDomain(forName: setup.suiteName) }
        let existing = setup.manager.upsertConnection(StoredConnection(
            server: PairedServer(
                hosts: ["10.0.0.1"],
                port: 4242,
                name: "existing",
                pairedAt: Date(),
                certFingerprint: "12:34"
            ),
            token: "existing-token"
        ))
        setup.manager.setActiveConnection(id: existing.id)
        storage.setSaveFailure(true)
        let fake = FakeConnectionManager()
        fake.responseMap["host.status"] = ["hostname": "test.local"]

        await #expect(throws: ConnectionPairing.PersistenceError.self) {
            try await PairingFlow.connect(
                payload: payload(fingerprint: "ab:cd"),
                certFingerprint: "ab:cd",
                connectionManager: fake,
                persistence: setup.manager
            )
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
            payload: payload(fingerprint: "ab:cd"),
            certFingerprint: "ab:cd",
            connectionManager: fake,
            persistence: setup.manager
        )

        #expect(setup.manager.loadConnections() == [stored])
        #expect(setup.manager.activeConnection()?.id == stored.id)
        #expect(fake.disconnectCallCount == 0)
    }

    @Test @MainActor func personalPairingsKeepTwoPeopleOnOnePinnedHost() async throws {
        let storage = InMemoryKeychainStorage()
        let setup = makePersistence(storage: storage)
        defer { UserDefaults(suiteName: setup.suiteName)?.removePersistentDomain(forName: setup.suiteName) }
        let pin = String(repeating: "ab", count: 32)
        let fake = FakeConnectionManager()
        fake.responseMap["client.hello"] = ["server": ["capabilities": ["hostMembership": 1]]]
        for person in ["B", "C", "B"] {
            fake.responseMap["principal.me"] = [
                "id": person, "isAdministrator": false, "hostRole": "member", "hostMembershipRevision": 1
            ]
            _ = try await PairingFlow.connect(
                payload: PairingPayload(hosts: ["test.invalid"], port: 443, token: "test-\(person)", certFingerprint: pin, tcAddress: "tc-test"),
                certFingerprint: pin,
                connectionManager: fake,
                persistence: setup.manager
            )
        }
        let relaunched = PersistenceManager(defaults: setup.manager.defaults, keychainStorage: storage)
        #expect(relaunched.loadConnections().count == 2)
        #expect(Set(relaunched.loadConnections().map(\.token)) == ["test-B", "test-C"])
        #expect(relaunched.loadConnections().allSatisfy { $0.server.tcAddress == "tc-test" })
    }

    @Test @MainActor func malformedPersonalIdentityCannotBeSaved() async {
        let storage = InMemoryKeychainStorage()
        let setup = makePersistence(storage: storage)
        defer { UserDefaults(suiteName: setup.suiteName)?.removePersistentDomain(forName: setup.suiteName) }
        let fake = FakeConnectionManager()
        fake.responseMap["client.hello"] = ["server": ["capabilities": ["hostMembership": 1]]]
        fake.responseMap["principal.me"] = ["id": "B", "isAdministrator": false]
        await #expect(throws: (any Error).self) {
            try await PairingFlow.connect(
                payload: payload(fingerprint: String(repeating: "ab", count: 32)),
                certFingerprint: String(repeating: "ab", count: 32),
                connectionManager: fake,
                persistence: setup.manager
            )
        }
        #expect(setup.manager.loadConnections().isEmpty)
        #expect(fake.disconnectCallCount == 1)
    }
}
