import Foundation
@testable import Intent
import Testing

extension SyncedBackendConnectionMergeTests {
    // MARK: - Tombstones

    @Test func tombstoneRemovesFingerprintMatch() {
        let existing = local()
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(updatedAt: 200, deleted: true)],
            into: [existing]
        )
        #expect(result.connections.isEmpty)
        #expect(result.removedIds == [existing.id])
    }

    @Test func tombstoneRemovesHostPortMatchWhenLocalHasNoFingerprint() {
        let existing = local(fingerprint: nil)
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(fingerprint: "", updatedAt: 200, deleted: true)],
            into: [existing]
        )
        #expect(result.removedIds == [existing.id])
    }

    @Test func tombstoneLosesToNewerLocalSyncClock() {
        let existing = local(syncUpdatedAt: 300)
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(updatedAt: 200, deleted: true)],
            into: [existing]
        )
        #expect(!result.changed)
        #expect(result.connections.count == 1)
    }

    @Test func tombstoneWithNoMatchIsANoOp() {
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(host: "9.9.9.9", fingerprint: "zz", deleted: true)],
            into: [local()]
        )
        #expect(!result.changed)
    }

    @Test func equalClockTombstoneRemovesSyncedLocal() {
        // Equal clocks delete — mirrors the fe reconcile's tie rule (an
        // address change must not dodge a delete).
        let existing = local(syncUpdatedAt: 200)
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(updatedAt: 200, deleted: true)],
            into: [existing]
        )
        #expect(result.removedIds == [existing.id])
    }

    @Test func staleTombstoneLosesToNewerLocalPairing() {
        // Re-pair race: a tombstone written BEFORE the user re-paired this
        // machine locally must not delete the fresh never-synced pairing.
        let repaired = Date(timeIntervalSince1970: 1000)
        let existing = local(syncUpdatedAt: nil, pairedAt: repaired)
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(updatedAt: 500_000, deleted: true)],
            into: [existing]
        )
        #expect(!result.changed)
        #expect(result.connections == [existing])
    }

    @Test func tombstoneNewerThanLocalPairingRemovesNeverSyncedLocal() {
        let existing = local(syncUpdatedAt: nil, pairedAt: Date(timeIntervalSince1970: 100))
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(updatedAt: 500_000, deleted: true)],
            into: [existing]
        )
        #expect(result.removedIds == [existing.id])
    }

    @Test func tombstoneWithDifferentFingerprintAtSameAddressDoesNotRemove() {
        // Another machine reusing the IP was forgotten: the tombstone must
        // not delete the local record with a different pinned cert.
        let existing = local(fingerprint: "aa:bb")
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(fingerprint: "cc:dd", updatedAt: 500_000, deleted: true)],
            into: [existing]
        )
        #expect(!result.changed)
        #expect(result.connections == [existing])
    }

    // MARK: - Absence and matching rules

    @Test func absenceFromRegistryNeverRemovesLocals() {
        let existing = local()
        let result = SyncedBackendConnectionMerge.merge(records: [], into: [existing])
        #expect(!result.changed)
        #expect(result.connections == [existing])
    }

    @Test func differentFingerprintAtSameAddressIsNotMatched() {
        // Another machine reusing the IP: must be added, never overwrite.
        let existing = local(fingerprint: "aa:bb")
        let other = record(fingerprint: "cc:dd", updatedAt: 200)
        let result = SyncedBackendConnectionMerge.merge(records: [other], into: [existing])
        #expect(result.connections.count == 2)
        #expect(result.addedIds.count == 1)
        #expect(result.updatedIds.isEmpty)
    }

    @Test func fingerprintMatchSurvivesAddressChange() {
        let existing = local(hosts: ["192.168.1.5"], port: 1111)
        let moved = record(host: "10.0.0.42", port: 2222, updatedAt: 200)
        let result = SyncedBackendConnectionMerge.merge(records: [moved], into: [existing])
        #expect(result.updatedIds == [existing.id])
        let updated = result.connections[0]
        #expect(updated.server.port == 2222)
        #expect(updated.server.hosts.first == "10.0.0.42")
        #expect(updated.server.hosts.contains("192.168.1.5"))
    }

    @Test func fingerprintMatchingNormalizesCaseAndWhitespace() {
        let existing = local(fingerprint: "  AA:bb ")
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(fingerprint: "aa:BB", updatedAt: 200)],
            into: [existing]
        )
        #expect(result.updatedIds == [existing.id])
    }

    @Test func hostPortFallbackMatchNormalizesHostCase() {
        let existing = local(hosts: ["Mac-Studio.Local"], fingerprint: nil)
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(host: "mac-studio.local", updatedAt: 200)],
            into: [existing]
        )
        #expect(result.updatedIds == [existing.id])
        // The fingerprint-less local gains the registry's fingerprint.
        #expect(result.connections[0].server.certFingerprint == "aa:bb")
    }

    @Test func hostPortFallbackRequiresSamePort() {
        let existing = local(fingerprint: nil, syncUpdatedAt: nil)
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(port: 9999, updatedAt: 200)],
            into: [existing]
        )
        #expect(result.addedIds.count == 1)
        #expect(result.connections.count == 2)
    }
}
