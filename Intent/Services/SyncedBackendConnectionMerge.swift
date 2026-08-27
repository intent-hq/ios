import Foundation

/// Merges the iCloud-synced backend registry (read by
/// `SyncedBackendRegistry.listBackends()`) into the app's saved connections.
/// iOS has no opt-out: every live registry record appears as a saved
/// connection, a newer remote copy overwrites the local fields
/// (last-writer-wins on `updatedAt`), and a tombstone removes the matching
/// local connection — matched by cert fingerprint first, `host:port` as
/// fallback. Absence is NOT deletion: local-only connections that predate
/// sync are never removed just because the registry doesn't list them (they
/// get pushed to the registry by the write-back path instead).
enum SyncedBackendConnectionMerge {

    /// Outcome of one merge pass over a saved-connections list.
    struct Result: Equatable {
        /// The full post-merge list (existing order preserved; new records
        /// appended in registry order).
        var connections: [StoredConnection]
        var addedIds: [UUID] = []
        var updatedIds: [UUID] = []
        var removedIds: [UUID] = []
        var changed: Bool { !(addedIds.isEmpty && updatedIds.isEmpty && removedIds.isEmpty) }
    }

    /// Pure merge core. `records` are the registry's per-key winners
    /// (including tombstones); `now` stamps `pairedAt` on newly added
    /// connections.
    static func merge(
        records: [SyncedBackendRecord],
        into connections: [StoredConnection],
        now: Date = Date()
    ) -> Result {
        var result = Result(connections: connections)
        for record in records {
            let index = matchIndex(for: record, in: result.connections)
            if record.deleted {
                guard let index else { continue }
                let existing = result.connections[index]
                // LWW guard for the cross-key fallback match: a local copy
                // synced from a live record NEWER than this tombstone wins.
                if let applied = existing.syncUpdatedAt, applied > record.updatedAt { continue }
                result.removedIds.append(existing.id)
                result.connections.remove(at: index)
            } else if let index {
                let existing = result.connections[index]
                // Only a strictly newer remote copy overwrites; a local
                // record that never synced (nil clock) adopts the registry
                // copy, gaining its fingerprint/token.
                if let applied = existing.syncUpdatedAt, record.updatedAt <= applied { continue }
                result.connections[index] = apply(record, to: existing)
                result.updatedIds.append(existing.id)
            } else {
                let added = makeConnection(from: record, now: now)
                result.connections.append(added)
                result.addedIds.append(added.id)
            }
        }
        return result
    }

    /// Index of the local connection a record refers to: cert fingerprint
    /// match first (the canonical identity — survives host/port changes),
    /// then `host:port` overlap among locals that carry NO fingerprint
    /// (connections paired before fingerprint capture). A local with a
    /// DIFFERENT fingerprint at the same address is never matched — that is
    /// another machine reusing the IP.
    static func matchIndex(
        for record: SyncedBackendRecord, in connections: [StoredConnection]
    ) -> Int? {
        let fingerprint = normalizeFingerprint(record.fingerprint)
        if !fingerprint.isEmpty,
            let index = connections.firstIndex(where: {
                normalizeFingerprint($0.server.certFingerprint) == fingerprint
            })
        {
            return index
        }
        let hosts = Set(candidateHosts(of: record).map(normalizeHost))
        return connections.firstIndex(where: { connection in
            normalizeFingerprint(connection.server.certFingerprint).isEmpty
                && connection.server.port == record.port
                && !hosts.isDisjoint(with: connection.server.hosts.map(normalizeHost))
        })
    }

    /// Same fingerprint normalization as `SyncedBackendRecord.registryKey`.
    static func normalizeFingerprint(_ raw: String?) -> String {
        (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func normalizeHost(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The record's candidate hosts: primary `host` first, then the rest of
    /// `hosts`, deduped.
    static func candidateHosts(of record: SyncedBackendRecord) -> [String] {
        PersistenceManager.mergeHostLists(existing: [record.host], incoming: record.hosts)
    }

    /// Display name mirroring the desktop convention: the record label
    /// already is "hostname, fallback host:port"; a blank label falls back
    /// to the raw hostname, then host:port.
    static func displayName(for record: SyncedBackendRecord) -> String {
        for candidate in [record.label, record.hostname ?? ""] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "\(record.host):\(record.port)"
    }

    /// Rewrites the local copy with the newer remote fields, preserving the
    /// record identity, pairing date and connection history. Remote hosts
    /// come first (primary route); locally learned extra routes are kept.
    private static func apply(
        _ record: SyncedBackendRecord, to existing: StoredConnection
    ) -> StoredConnection {
        StoredConnection(
            id: existing.id,
            server: PairedServer(
                hosts: PersistenceManager.mergeHostLists(
                    existing: candidateHosts(of: record), incoming: existing.server.hosts),
                port: record.port,
                name: existing.server.name,
                pairedAt: existing.server.pairedAt,
                certFingerprint: fingerprintOrNil(record) ?? existing.server.certFingerprint),
            token: record.token,
            displayName: displayName(for: record),
            lastConnectedAt: existing.lastConnectedAt,
            syncUpdatedAt: record.updatedAt)
    }

    private static func makeConnection(from record: SyncedBackendRecord, now: Date)
        -> StoredConnection
    {
        let name = displayName(for: record)
        return StoredConnection(
            server: PairedServer(
                hosts: candidateHosts(of: record),
                port: record.port,
                name: name,
                pairedAt: now,
                certFingerprint: fingerprintOrNil(record)),
            token: record.token,
            displayName: name,
            syncUpdatedAt: record.updatedAt)
    }

    private static func fingerprintOrNil(_ record: SyncedBackendRecord) -> String? {
        let trimmed = record.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Outcome of merging the registry into the persisted connections
/// (`PersistenceManager.mergeSyncedBackends`).
struct SyncedBackendMergeOutcome: Equatable {
    var addedIds: [UUID]
    var updatedIds: [UUID]
    var removedIds: [UUID]
    /// True when a tombstone removed the connection that was active — the
    /// caller must disconnect and route away from it.
    var removedActiveConnection: Bool
    var changed: Bool { !(addedIds.isEmpty && updatedIds.isEmpty && removedIds.isEmpty) }
}
