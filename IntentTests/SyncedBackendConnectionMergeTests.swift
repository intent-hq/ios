import Foundation
import Testing

@testable import Intent

/// Merge matrix for `SyncedBackendConnectionMerge`: new/newer/older/tombstone/
/// absent records, fingerprint vs host:port matching, token rotation.
struct SyncedBackendConnectionMergeTests {

    private func record(
        label: String = "Mac Studio", host: String = "10.0.0.1", hosts: [String]? = nil,
        port: Int = 8843, fingerprint: String = "aa:bb", token: String = "tok-remote",
        updatedAt: Double = 100, deleted: Bool = false
    ) -> SyncedBackendRecord {
        SyncedBackendRecord(
            label: label, host: host, hosts: hosts ?? [host], port: port,
            fingerprint: fingerprint, hostname: nil, detectHosts: true,
            token: deleted ? "" : token, updatedAt: updatedAt,
            deleted: deleted, deletedAt: deleted ? updatedAt : nil)
    }

    private func local(
        hosts: [String] = ["10.0.0.1"], port: Int = 8843, fingerprint: String? = "aa:bb",
        token: String = "tok-local", syncUpdatedAt: Double? = nil
    ) -> StoredConnection {
        StoredConnection(
            server: PairedServer(
                hosts: hosts, port: port, name: "daemon", pairedAt: Date(),
                certFingerprint: fingerprint),
            token: token, syncUpdatedAt: syncUpdatedAt)
    }

    // MARK: - New records

    @Test func newRecordIsAddedWithTokenFingerprintAndClock() {
        let result = SyncedBackendConnectionMerge.merge(records: [record()], into: [])
        #expect(result.connections.count == 1)
        #expect(result.addedIds == result.connections.map(\.id))
        let added = result.connections[0]
        #expect(added.token == "tok-remote")
        #expect(added.server.certFingerprint == "aa:bb")
        #expect(added.server.hosts == ["10.0.0.1"])
        #expect(added.server.port == 8843)
        #expect(added.displayName == "Mac Studio")
        #expect(added.syncUpdatedAt == 100)
    }

    @Test func blankLabelFallsBackToHostnameThenHostPort() {
        #expect(
            SyncedBackendConnectionMerge.displayName(
                for: record(label: "  ")) == "10.0.0.1:8843")
        var withHostname = record(label: " ")
        withHostname.hostname = "mac-studio.local"
        #expect(SyncedBackendConnectionMerge.displayName(for: withHostname) == "mac-studio.local")
    }

    // MARK: - LWW updates

    @Test func newerRecordOverwritesRotatedTokenAndFields() {
        let existing = local(syncUpdatedAt: 100)
        let newer = record(label: "Renamed", host: "10.9.9.9", token: "tok-rotated", updatedAt: 200)
        let result = SyncedBackendConnectionMerge.merge(records: [newer], into: [existing])
        #expect(result.updatedIds == [existing.id])
        let updated = result.connections[0]
        #expect(updated.id == existing.id)
        #expect(updated.token == "tok-rotated")
        #expect(updated.displayName == "Renamed")
        #expect(updated.server.hosts == ["10.9.9.9", "10.0.0.1"])
        #expect(updated.syncUpdatedAt == 200)
    }

    @Test func olderOrEqualRecordDoesNotOverwrite() {
        let existing = local(syncUpdatedAt: 200)
        for clock in [100.0, 200.0] {
            let result = SyncedBackendConnectionMerge.merge(
                records: [record(token: "tok-stale", updatedAt: clock)], into: [existing])
            #expect(!result.changed)
            #expect(result.connections[0].token == "tok-local")
        }
    }

    @Test func neverSyncedLocalAdoptsTheRegistryCopy() {
        // nil clock: a locally paired record matched by fingerprint adopts the
        // registry copy (gains its token) no matter how small its updatedAt.
        let existing = local(syncUpdatedAt: nil)
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(updatedAt: 1)], into: [existing])
        #expect(result.updatedIds == [existing.id])
        #expect(result.connections[0].token == "tok-remote")
        #expect(result.connections[0].syncUpdatedAt == 1)
    }

    // MARK: - Tombstones

    @Test func tombstoneRemovesFingerprintMatch() {
        let existing = local()
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(updatedAt: 200, deleted: true)], into: [existing])
        #expect(result.connections.isEmpty)
        #expect(result.removedIds == [existing.id])
    }

    @Test func tombstoneRemovesHostPortMatchWhenLocalHasNoFingerprint() {
        let existing = local(fingerprint: nil)
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(fingerprint: "", updatedAt: 200, deleted: true)], into: [existing])
        #expect(result.removedIds == [existing.id])
    }

    @Test func tombstoneLosesToNewerLocalSyncClock() {
        let existing = local(syncUpdatedAt: 300)
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(updatedAt: 200, deleted: true)], into: [existing])
        #expect(!result.changed)
        #expect(result.connections.count == 1)
    }

    @Test func tombstoneWithNoMatchIsANoOp() {
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(host: "9.9.9.9", fingerprint: "zz", deleted: true)],
            into: [local()])
        #expect(!result.changed)
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
            records: [record(fingerprint: "aa:BB", updatedAt: 200)], into: [existing])
        #expect(result.updatedIds == [existing.id])
    }

    @Test func hostPortFallbackMatchNormalizesHostCase() {
        let existing = local(hosts: ["Mac-Studio.Local"], fingerprint: nil)
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(host: "mac-studio.local", updatedAt: 200)], into: [existing])
        #expect(result.updatedIds == [existing.id])
        // The fingerprint-less local gains the registry's fingerprint.
        #expect(result.connections[0].server.certFingerprint == "aa:bb")
    }

    @Test func hostPortFallbackRequiresSamePort() {
        let existing = local(fingerprint: nil, syncUpdatedAt: nil)
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(port: 9999, updatedAt: 200)], into: [existing])
        #expect(result.addedIds.count == 1)
        #expect(result.connections.count == 2)
    }
}
