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

    @Test(arguments: [false, true])
    func pairingSuccessIsRecordedOnlyAfterDurableSave(manualEntry: Bool) async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        let suiteName = "PairingDiagnostics-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = InMemoryKeychainStorage()
        let persistence = PersistenceManager(defaults: defaults, keychainStorage: storage)
        let connection = FakeConnectionManager()
        connection.responseMap["host.status"] = ["hostname": "private-name"]
        storage.setSaveFailure(true)
        await #expect(throws: ConnectionPairing.PersistenceError.saveFailed) {
            try await pair(manualEntry: manualEntry, connection: connection, persistence: persistence, diagnostics: store)
        }
        var records = try DiagnosticFixtures.records(await store.snapshot())
        #expect(records.map(\.event.stage) == [.connect, .save, .save])
        #expect(records.map(\.event.outcome) == [.started, .started, .failed])
        #expect(connection.connectLog.count == 1)
        #expect(connection.disconnectCallCount == 1)
        #expect(connection.connectionState == .disconnected)
        #expect(persistence.loadConnections().isEmpty)
        #expect(persistence.activeConnection() == nil)
        storage.setSaveFailure(false)
        let stored = try await pair(manualEntry: manualEntry, connection: connection, persistence: persistence, diagnostics: store)
        records = try DiagnosticFixtures.records(await store.snapshot())
        #expect(records.map(\.event.stage) == [.connect, .save, .save, .connect, .save, .save])
        #expect(records.map(\.event.outcome) == [.started, .started, .failed, .started, .started, .succeeded])
        #expect(persistence.loadConnections() == [stored])
        #expect(persistence.activeConnection()?.id == stored.id)
        #expect(connection.disconnectCallCount == 1)
        #expect(connection.connectionState == .connected)
    }

    @Test(arguments: [false, true])
    func manualConnectionFailureAndCancellationDoNotStartSaving(cancelled: Bool) async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        let suiteName = "ManualPairingDiagnostics-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = PersistenceManager(defaults: defaults, keychainStorage: InMemoryKeychainStorage())
        let connection = FakeConnectionManager()
        if cancelled {
            connection.connectError = CancellationError()
        } else {
            connection.connectError = URLError(.cannotConnectToHost)
        }
        do {
            _ = try await pair(manualEntry: true, connection: connection, persistence: persistence, diagnostics: store)
            Issue.record("Expected the original connection error")
        } catch is CancellationError {
            #expect(cancelled)
        } catch let error as URLError {
            #expect(!cancelled)
            #expect(error.code == .cannotConnectToHost)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        let records = try DiagnosticFixtures.records(await store.snapshot())
        #expect(records.map(\.event.stage) == [.connect, .connect])
        #expect(records.map(\.event.outcome) == [.started, cancelled ? .cancelled : .failed])
        #expect(connection.connectLog.count == 1)
        #expect(connection.requestLog.isEmpty)
        #expect(connection.disconnectCallCount == 0)
        #expect(persistence.loadConnections().isEmpty)
        #expect(persistence.activeConnection() == nil)
    }

    private func pair(
        manualEntry: Bool,
        connection: FakeConnectionManager,
        persistence: PersistenceManager,
        diagnostics: DiagnosticStore
    ) async throws -> StoredConnection {
        if manualEntry {
            return try await ManualTokenEntryView.connectAndSave(
                input: .direct(host: "private-host"),
                port: 4242,
                fingerprint: "private-pin",
                token: "private-token",
                connection: connection,
                persistence: persistence,
                diagnostics: diagnostics
            )
        }
        let payload = PairingPayload(hosts: ["private-host"], port: 4242, token: "private-token", certFingerprint: "private-pin", tcAddress: nil)
        return try await PairingFlow.connect(
            payload: payload, certFingerprint: "private-pin", connectionManager: connection, persistence: persistence, diagnostics: diagnostics
        )
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
