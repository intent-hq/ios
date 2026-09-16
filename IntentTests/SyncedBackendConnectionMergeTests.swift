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
        token: String = "tok-local", syncUpdatedAt: Double? = nil,
        pairedAt: Date = Date(timeIntervalSince1970: 0), tcAddress: String? = nil
    ) -> StoredConnection {
        StoredConnection(
            server: PairedServer(
                hosts: hosts, port: port, name: "daemon", pairedAt: pairedAt,
                certFingerprint: fingerprint, tcAddress: tcAddress),
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

    @Test func fingerprintlessNewRecordIsNeverAdded() {
        // Without a pinned cert the connection would fall back to plain
        // ws:// and leak the synced token — such records must not be adopted.
        for fingerprint in ["", "   "] {
            let result = SyncedBackendConnectionMerge.merge(
                records: [record(fingerprint: fingerprint)], into: [])
            #expect(!result.changed)
            #expect(result.connections.isEmpty)
        }
    }

    @Test func malformedHostsAreDroppedAndHostlessRecordsAreNeverAdded() {
        // Registry host strings are untrusted; raceHosts force-unwraps
        // URL(string:), so a malformed host must never survive the merge.
        let mixed = record(host: "10.0.0.1", hosts: ["10.0.0.1", "bad host", "mac.local"])
        let result = SyncedBackendConnectionMerge.merge(records: [mixed], into: [])
        #expect(result.connections.map(\.server.hosts) == [["10.0.0.1", "mac.local"]])

        // A record with NO usable host cannot be connected to: skip it.
        let hostless = record(host: "spaces in host", hosts: ["also/bad", "with spaces"])
        #expect(!SyncedBackendConnectionMerge.merge(records: [hostless], into: []).changed)
    }

    @Test func usableHostAcceptsNamesAndAddressesRejectsUrlMetacharacters() {
        for good in ["10.0.0.1", "mac-studio.local", "MAC.Local", "[::1]", "host123"] {
            #expect(SyncedBackendConnectionMerge.usableHost(good) == good, "expected usable: \(good)")
        }
        for bad in [
            "", "  ", "a b", "host/path", "host:1", "user@host", "host?q", "host#f", "[::1", "[]",
            "::::", "2001::db8::1", "[2001::db8::1]", ":", "12345::1",
        ] {
            #expect(
                SyncedBackendConnectionMerge.usableHost(bad) == nil, "expected unusable: \(bad)")
        }
    }

    @Test func rawIPv6LiteralsAreBracketNormalizedNotDropped() {
        // intentd advertises RAW unbracketed IPv6 strings in pairing/registry
        // hosts (collect_local_ipv6s emits e.g. "2001:db8::1"); they must be
        // bracket-normalized for URL embedding, not silently dropped.
        #expect(SyncedBackendConnectionMerge.usableHost("2001:db8::1") == "[2001:db8::1]")
        #expect(SyncedBackendConnectionMerge.usableHost("::1") == "[::1]")

        let v6only = record(host: "2001:db8::1", hosts: ["2001:db8::1", "fd00::2"])
        let result = SyncedBackendConnectionMerge.merge(records: [v6only], into: [])
        #expect(result.connections.map(\.server.hosts) == [["[2001:db8::1]", "[fd00::2]"]])
    }

    @Test func fingerprintlessRecordStillUpdatesExistingFingerprintlessLocal() {
        // The host:port fallback still applies: a record the user paired on
        // this device (fingerprint-less local) keeps receiving updates.
        let existing = local(fingerprint: nil)
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(fingerprint: "", token: "tok-new", updatedAt: 200)],
            into: [existing])
        #expect(result.updatedIds == [existing.id])
        #expect(result.connections[0].token == "tok-new")
    }

    /// ios#251: merging a pin-less record into a pin-less legacy local keeps
    /// the record (name, hosts, port intact) but never fabricates a pin, so
    /// the connection stays refused by transport admission until re-paired.
    @Test func fingerprintlessMergeNeverMakesLegacyLocalConnectable() throws {
        let existing = local(fingerprint: nil)
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(fingerprint: "  ", token: "tok-new", updatedAt: 200)],
            into: [existing])
        let merged = try #require(result.connections.first)
        #expect(merged.id == existing.id)
        #expect(merged.server.hosts == existing.server.hosts)
        #expect(merged.server.port == existing.server.port)
        #expect(merged.server.name == existing.server.name)
        #expect(WebSocketConnection.trustedPin(merged.server.certFingerprint) == nil)
        #expect(throws: WebSocketTransportError.self) {
            _ = try WebSocketConnection.makeURL(
                host: merged.server.hosts[0], port: merged.server.port,
                certFingerprint: merged.server.certFingerprint)
        }
    }

    /// A pinned local is never downgraded: a pin-less record at the same
    /// address does not match it, so its pin (and connectability) survive.
    @Test func fingerprintlessRecordNeverStripsPinFromPinnedLocal() {
        let existing = local(fingerprint: "aa:bb")
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(fingerprint: "", token: "tok-new", updatedAt: 200)],
            into: [existing])
        #expect(!result.changed)
        #expect(result.connections[0].server.certFingerprint == "aa:bb")
        #expect(result.connections[0].token == "tok-local")
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

    /// Registry records carry no tunnel address; a registry-driven rewrite
    /// must keep the locally learned one.
    @Test func newerRecordPreservesLocalTcAddress() {
        let existing = local(syncUpdatedAt: 100, tcAddress: "tc-local-tunnel")
        let newer = record(token: "tok-rotated", updatedAt: 200)
        let result = SyncedBackendConnectionMerge.merge(records: [newer], into: [existing])
        #expect(result.updatedIds == [existing.id])
        #expect(result.connections[0].server.tcAddress == "tc-local-tunnel")
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
        // nil clock: a locally paired record matched by fingerprint adopts a
        // registry copy newer than its pairing time (gains its token). The
        // helper's default pairedAt is the epoch, so even updatedAt: 1 wins.
        let existing = local(syncUpdatedAt: nil)
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(updatedAt: 1)], into: [existing])
        #expect(result.updatedIds == [existing.id])
        #expect(result.connections[0].token == "tok-remote")
        #expect(result.connections[0].syncUpdatedAt == 1)
    }

    @Test func staleLiveRecordDoesNotClobberFreshLocalRePairing() {
        // Same race as the stale-tombstone guard, live variant: the user
        // re-pairs directly (fresh token, nil sync clock) while the Mac's
        // registry copy lags behind a rotation — the stale copy must not
        // overwrite the fresh working token.
        let repaired = Date(timeIntervalSince1970: 1000)
        let existing = local(syncUpdatedAt: nil, pairedAt: repaired)
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(token: "tok-stale", updatedAt: 500_000)], into: [existing])
        #expect(!result.changed)
        #expect(result.connections[0].token == "tok-local")
        #expect(result.connections[0].syncUpdatedAt == nil)
    }

    @Test func liveRecordNewerThanLocalPairingUpdatesNeverSyncedLocal() {
        let existing = local(syncUpdatedAt: nil, pairedAt: Date(timeIntervalSince1970: 100))
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(updatedAt: 500_000)], into: [existing])
        #expect(result.updatedIds == [existing.id])
        #expect(result.connections[0].token == "tok-remote")
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

    @Test func equalClockTombstoneRemovesSyncedLocal() {
        // Equal clocks delete — mirrors the fe reconcile's tie rule (an
        // address change must not dodge a delete).
        let existing = local(syncUpdatedAt: 200)
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(updatedAt: 200, deleted: true)], into: [existing])
        #expect(result.removedIds == [existing.id])
    }

    @Test func staleTombstoneLosesToNewerLocalPairing() {
        // Re-pair race: a tombstone written BEFORE the user re-paired this
        // machine locally must not delete the fresh never-synced pairing.
        let repaired = Date(timeIntervalSince1970: 1000)
        let existing = local(syncUpdatedAt: nil, pairedAt: repaired)
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(updatedAt: 500_000, deleted: true)], into: [existing])
        #expect(!result.changed)
        #expect(result.connections == [existing])
    }

    @Test func tombstoneNewerThanLocalPairingRemovesNeverSyncedLocal() {
        let existing = local(syncUpdatedAt: nil, pairedAt: Date(timeIntervalSince1970: 100))
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(updatedAt: 500_000, deleted: true)], into: [existing])
        #expect(result.removedIds == [existing.id])
    }

    @Test func tombstoneWithDifferentFingerprintAtSameAddressDoesNotRemove() {
        // Another machine reusing the IP was forgotten: the tombstone must
        // not delete the local record with a different pinned cert.
        let existing = local(fingerprint: "aa:bb")
        let result = SyncedBackendConnectionMerge.merge(
            records: [record(fingerprint: "cc:dd", updatedAt: 500_000, deleted: true)],
            into: [existing])
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
