import Foundation
@testable import Intent
import Network
import SwiftUI
import Testing

@MainActor struct PairingLifecycleDiagnosticTests {
    @Test func probeFailureThenRecoveryKeepsBothWithoutHostsOrFingerprint() async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        let result = await CertFingerprintProbe.probeFirst(hosts: ["private-host", "private-winner"], port: 4242, diagnostics: store) { host, _ in
            host == "private-host" ? .timeout : .fingerprint("private-fingerprint")
        }
        #expect(result == .fingerprint("private-fingerprint"))
        let snapshot = await store.snapshot()
        let records = try DiagnosticFixtures.records(snapshot)
        #expect(records.map(\.event.outcome) == [.fallbackPending, .recovered])
        #expect(records.first?.event.failure.classification == .requestTimeout)
        #expect(try #require(String(data: snapshot.jsonLines, encoding: .utf8)).contains("private-") == false)
    }

    @Test func failedAndCancelledPairingProbesAreDistinct() async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        let payload = PairingPayload(hosts: ["private-host"], port: 4242, token: "private-token", certFingerprint: nil, tcAddress: nil)
        _ = await PairingFlow.resolveFingerprint(for: payload, diagnostics: store) { _, _ in .noCertificate }
        _ = await PairingFlow.resolveFingerprint(for: payload, diagnostics: store) { _, _ in .cancelled }
        let records = try DiagnosticFixtures.records(await store.snapshot())
        let failed = records.filter { $0.event.failure != .none }
        #expect(failed.count == 1)
        #expect(failed.first?.event.failure.classification == .noCertificate)
        #expect(records.last?.event.outcome == .cancelled)
        #expect(records.last?.event.failure == DiagnosticFailure.none)
    }

    @Test func pairingSuccessIsRecordedOnlyAfterDurableSave() async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        let suiteName = "PairingDiagnostics-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = InMemoryKeychainStorage()
        let persistence = PersistenceManager(defaults: defaults, keychainStorage: storage)
        let connection = FakeConnectionManager()
        connection.responseMap["host.status"] = ["hostname": "private-name"]
        let payload = PairingPayload(hosts: ["private-host"], port: 4242, token: "private-token", certFingerprint: "private-pin", tcAddress: nil)
        storage.setSaveFailure(true)
        do {
            _ = try await PairingFlow.connect(payload: payload, certFingerprint: "private-pin", connectionManager: connection, persistence: persistence, diagnostics: store)
            Issue.record("Expected save failure")
        } catch {}
        var records = try DiagnosticFixtures.records(await store.snapshot())
        #expect(records.last?.event.stage == .save)
        #expect(records.last?.event.outcome == .failed)
        #expect(connection.disconnectCallCount == 1)
        storage.setSaveFailure(false)
        _ = try await PairingFlow.connect(payload: payload, certFingerprint: "private-pin", connectionManager: connection, persistence: persistence, diagnostics: store)
        records = try DiagnosticFixtures.records(await store.snapshot())
        #expect(records.last?.event.stage == .save)
        #expect(records.last?.event.outcome == .succeeded)
        #expect(persistence.loadConnections().count == 1)
    }

    @Test func scannerAndInputFailuresUseOnlyClosedValues() async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        PairingDiagnostics.invalidInput(store: store)
        PairingDiagnostics.scanner(.scannerStart, failure: .startFailed, store: store)
        PairingDiagnostics.scanner(.scannerAvailability, failure: .permissionDenied, store: store)
        PairingDiagnostics.scanner(.scannerAvailability, failure: .unavailable, store: store)
        let records = try DiagnosticFixtures.records(await store.snapshot())
        #expect(records.map(\.event.failure.classification) == [.invalidInput, .startFailed, .permissionDenied, .unavailable])
        #expect(records.map(\.event.stage) == [.input, .start, .permission, .permission])
    }

    @Test func lifecycleAndNetworkRecordOnlyAcceptedChanges() async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        LifecycleDiagnostics.sessionStarted(store: store)
        let lifecycle = LifecycleDiagnostics(store: store)
        lifecycle.scene(.active)
        lifecycle.scene(.active)
        lifecycle.scene(.background)
        lifecycle.stopped()
        lifecycle.stopped()
        let monitor = NetworkAvailabilityTests.FakeMonitor()
        let availability = NetworkAvailability(makeMonitor: { monitor }, diagnostics: store)
        let lease = availability.acquire()
        monitor.report(.satisfied)
        monitor.report(.satisfied)
        monitor.report(.unsatisfied, reason: .localNetworkDenied)
        lease.cancel()
        monitor.report(.satisfied)
        let records = try DiagnosticFixtures.records(await store.snapshot())
        #expect(records.map(\.event.context) == [.none, .active, .background, .stopped, .satisfied, .localNetworkDenied, .unknown])
        #expect(records.allSatisfy { $0.count == 1 && $0.event.failure == .none })
    }
}
