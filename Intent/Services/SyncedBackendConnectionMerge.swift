import Foundation

/// Merges the iCloud-synced backend registry (read by
/// `SyncedBackendRegistry.listBackends()`) into the app's saved connections.
/// iOS has no opt-out: every live registry record WITH a cert fingerprint
/// appears as a saved connection (fingerprint-less records are never
/// auto-added — no pinned cert means a plain-`ws://` fallback that would
/// leak the synced token), a newer remote copy overwrites the local fields
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
                // LWW guard: the local copy wins when its clock is strictly
                // newer than the tombstone (equal clocks delete — the fe's
                // tie rule). A local that never synced has no registry
                // clock, so its pairing time stands in: a stale tombstone
                // written before the user re-paired this machine must not
                // delete the fresh pairing.
                let localClock =
                    existing.syncUpdatedAt
                    ?? existing.server.pairedAt.timeIntervalSince1970 * 1000
                if localClock > record.updatedAt { continue }
                result.removedIds.append(existing.id)
                result.connections.remove(at: index)
            } else if let index {
                let existing = result.connections[index]
                // Only a strictly newer remote copy overwrites. A local that
                // never synced adopts the registry copy (gaining its
                // fingerprint/token), but its pairing time stands in as the
                // clock — same guard as the tombstone path — so a stale
                // registry copy lagging behind a token rotation cannot
                // clobber a fresh direct re-pairing.
                if let applied = existing.syncUpdatedAt {
                    if record.updatedAt <= applied { continue }
                } else if record.updatedAt
                    < existing.server.pairedAt.timeIntervalSince1970 * 1000
                {
                    continue
                }
                result.connections[index] = apply(record, to: existing)
                result.updatedIds.append(existing.id)
            } else {
                // Never auto-add a fingerprint-less record: without a pinned
                // cert the socket falls back to plain ws://, which would send
                // the synced bearer token in cleartext to an unauthenticated
                // host. (Existing fingerprint-less locals were paired by the
                // user on this device; the host:port fallback above can still
                // update them.)
                guard !normalizeFingerprint(record.fingerprint).isEmpty,
                    !candidateHosts(of: record).isEmpty
                else { continue }
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
    /// `hosts`, deduped — keeping only hosts usable in a WebSocket URL,
    /// bracket-normalizing raw IPv6 literals. Registry strings are untrusted
    /// input and `ConnectionManager.raceHosts` force-unwraps `URL(string:)`,
    /// so a malformed host must never survive the merge.
    static func candidateHosts(of record: SyncedBackendRecord) -> [String] {
        PersistenceManager.mergeHostLists(
            existing: [record.host], incoming: record.hosts
        ).compactMap(usableHost)
    }

    /// The URL-embeddable form of the host string, or nil when it has no
    /// safe form. Accepts a plain DNS name / IPv4 address or an IPv6
    /// literal — raw IPv6 strings (intentd's pairing_hosts advertises
    /// unbracketed `2001:db8::1` forms) are bracket-normalized. Anything
    /// else is rejected: a deterministic allowlist on purpose, since iOS
    /// 17+'s lenient URL parser would percent-encode junk instead of
    /// failing, hiding the problem until connect.
    static func usableHost(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        let inner: Substring
        if raw.hasPrefix("[") {
            guard raw.hasSuffix("]"), raw.count > 2 else { return nil }
            inner = raw.dropFirst().dropLast()
        } else if raw.contains(":") {
            inner = raw[...]
        } else {
            let usable = raw.allSatisfy { char in
                char.isLetter && char.isASCII || char.isNumber && char.isASCII
                    || char == "-" || char == "." || char == "_"
            }
            return usable ? raw : nil
        }
        // IPv6 literal (bare or bracketed): hex digits and colons only.
        return inner.allSatisfy { $0.isHexDigit && $0.isASCII || $0 == ":" }
            ? "[\(inner)]" : nil
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
                certFingerprint: fingerprintOrNil(record) ?? existing.server.certFingerprint,
                // Registry records don't carry the tunnel address; keep the
                // locally learned one.
                tcAddress: existing.server.tcAddress),
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
    /// True when the merge was skipped because the saved-connections blob
    /// exists but could not be decoded; nothing was written so the original
    /// blob is preserved (intent-hq/ios#265).
    var registryUndecodable: Bool = false
    var changed: Bool { !(addedIds.isEmpty && updatedIds.isEmpty && removedIds.isEmpty) }
}
