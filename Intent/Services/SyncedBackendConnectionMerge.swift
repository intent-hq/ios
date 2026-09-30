import Foundation
import Network

/// Merges the iCloud-synced backend registry (read by
/// `SyncedBackendRegistry.listBackends()`) into the app's saved connections.
/// iOS has no opt-out: every live registry record WITH a cert fingerprint
/// appears as a saved connection (fingerprint-less records are never
/// auto-added — without a pinned cert the transport refuses to connect
/// (ios#251), so the record could only ever surface as a re-pair prompt
/// for a host this device never trusted), a newer remote copy overwrites the local fields
/// (last-writer-wins on `updatedAt`), and a tombstone removes the matching
/// local connection — matched by cert fingerprint first, `host:port` as
/// fallback. Absence is NOT deletion: local-only connections that predate
/// sync are never removed just because the registry doesn't list them (they
/// get pushed to the registry by the write-back path instead).
enum SyncedBackendConnectionMerge {
    // Date.timeIntervalSince1970 is expressed in seconds.
    private static let millisecondsPerSecond: TimeInterval = 1000

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
                    existing.pendingSyncUpdatedAt ?? existing.syncUpdatedAt
                    ?? existing.server.pairedAt.timeIntervalSince1970 * Self.millisecondsPerSecond
                if localClock > record.updatedAt { continue }
                result.removedIds.append(existing.id)
                result.connections.remove(at: index)
            } else if let index {
                let existing = result.connections[index]
                guard let updated = mergeLive(record, into: existing) else { continue }
                result.connections[index] = updated
                result.updatedIds.append(existing.id)
            } else {
                // Never auto-add a fingerprint-less record: without a pinned
                // cert the transport refuses to connect (ios#251), so the
                // record would only ever surface as a re-pair prompt for a
                // host this device never trusted. (Existing fingerprint-less
                // locals were paired by the user on this device; the
                // host:port fallback above can still update them.)
                guard !normalizeFingerprint(record.fingerprint).isEmpty,
                    !candidateHosts(of: record).isEmpty || record.tcAddress != nil
                else { continue }
                let added = makeConnection(from: record, now: now)
                result.connections.append(added)
                result.addedIds.append(added.id)
            }
        }
        return result
    }

    /// A pending direct re-pair protects its new credentials even before
    /// publication. Otherwise only newer shared clocks replace local fields,
    /// except for the missing-route upgrade on already-imported records.
    private static func mergeLive(_ record: SyncedBackendRecord, into existing: StoredConnection) -> StoredConnection? {
        if let pending = existing.pendingSyncUpdatedAt {
            if record.updatedAt < pending { return nil }
        } else if let applied = existing.syncUpdatedAt {
            if applied != 0, record.updatedAt == applied,
               SyncedBackendPayload.tunnelAddress(existing.server.tcAddress) == nil,
               let route = record.tcAddress { return addingRoute(route, to: existing) }
            if record.updatedAt <= applied { return nil }
        } else if record.updatedAt < existing.server.pairedAt.timeIntervalSince1970 * Self.millisecondsPerSecond {
            return nil
        }
        return apply(record, to: existing)
    }

    /// Additive-field upgrade for records imported before iOS read tcAddress.
    /// Equal clocks authorize learning the missing route only, not replacing
    /// credentials, metadata, or the shared clock.
    private static func addingRoute(_ route: String, to connection: StoredConnection) -> StoredConnection {
        var updated = connection
        let server = connection.server
        updated.server = PairedServer(
            hosts: server.hosts,
            port: server.port,
            name: server.name,
            pairedAt: server.pairedAt,
            certFingerprint: server.certFingerprint,
            tcAddress: route
        )
        return updated
    }

    /// Index of the local connection a record refers to: cert fingerprint
    /// match first (the canonical identity — survives host/port changes),
    /// then `host:port` overlap among locals that carry NO fingerprint
    /// (connections paired before fingerprint capture). A local with a
    /// DIFFERENT fingerprint at the same address is never matched — that is
    /// another machine reusing the IP.
    static func matchIndex(
        for record: SyncedBackendRecord,
        in connections: [StoredConnection]
    ) -> Int? {
        let fingerprint = normalizeFingerprint(record.fingerprint)
        if !fingerprint.isEmpty,
            let index = connections.firstIndex(where: { connection in
                connection.invitedPersonKey == nil && normalizeFingerprint(connection.server.certFingerprint) == fingerprint
            }) {
            return index
        }
        let hosts = Set(candidateHosts(of: record).map(normalizeHost))
        return connections.firstIndex { connection in
            connection.invitedPersonKey == nil && normalizeFingerprint(connection.server.certFingerprint).isEmpty
                && connection.server.port == record.port
                && !hosts.isDisjoint(with: connection.server.hosts.map(normalizeHost))
        }
    }

    /// Same fingerprint normalization as `SyncedBackendRecord.registryKey`.
    static func normalizeFingerprint(_ raw: String?) -> String {
        (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func normalizeHost(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The record's candidate hosts: primary `host` first, then the rest of
    /// `hosts`, keeping only hosts usable in a WebSocket URL and
    /// bracket-normalizing raw IPv6 literals, then deduped. Validation runs
    /// BEFORE dedup so `2001:DB8::1` and `[2001:db8::1]` collapse to one
    /// route and an unusable primary (e.g. padded with spaces) never masks
    /// a usable spelling of the same host. Registry strings are untrusted
    /// input and `ConnectionManager.raceHosts` force-unwraps `URL(string:)`,
    /// so a malformed host must never survive the merge.
    static func candidateHosts(of record: SyncedBackendRecord) -> [String] {
        PersistenceManager.mergeHostLists(
            // A tunnel-only publisher uses its opaque route as the required
            // v1 host identity. That blob must not become a DNS candidate.
            existing: record.host == record.tcAddress ? [] : [record.host].compactMap(usableHost),
            incoming: record.hosts.filter { $0 != record.tcAddress }.compactMap(usableHost)
        )
    }

    /// The URL-embeddable form of the host string, or nil when it has no
    /// safe form. Accepts a structurally valid DNS name / IPv4 address or an
    /// IPv6 literal — raw IPv6 strings (intentd's pairing_hosts advertises
    /// unbracketed `2001:db8::1` forms) are bracket-normalized. Anything
    /// else is rejected: a deterministic allowlist on purpose, since iOS
    /// 17+'s lenient URL parser would percent-encode junk instead of
    /// failing, hiding the problem until connect. Spelling is preserved
    /// (`MAC.Local` stays as entered); callers dedup on `normalizeHost`.
    static func usableHost(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        let inner: Substring
        if raw.hasPrefix("[") {
            guard raw.hasSuffix("]"), raw.count > 2 else { return nil }
            inner = raw.dropFirst().dropLast()
        } else if raw.contains(":") {
            inner = raw[...]
        } else {
            return isValidNameOrIPv4(raw) ? raw : nil
        }
        // IPv6 literal (bare or bracketed): hex digits and colons only, and
        // structurally valid — the character allowlist alone admits `::::`.
        guard inner.allSatisfy({ $0.isHexDigit && $0.isASCII || $0 == ":" }),
            IPv6Address(String(inner)) != nil
        else { return nil }
        return "[\(inner)]"
    }

    // RFC 1035 presentation-form limits.
    private static let maxHostNameLength = 253
    private static let maxHostLabelLength = 63
    private static let ipv4OctetCount = 4
    private static let maxIPv4OctetDigits = 3
    private static let maxIPv4OctetValue = 255

    /// Structural check for the non-IPv6 branch (ios#341). A DNS name is
    /// dot-separated labels of 1–63 ASCII letters/digits/hyphens/underscores
    /// (underscores stay allowed for local names such as `my-mac_2.local`),
    /// no label starting or ending with a hyphen, no empty label — so no
    /// leading, trailing or doubled dot — and at most 253 characters. A
    /// string made only of digits and dots is an IPv4 literal and must be a
    /// dotted quad with octets 0–255 and no leading zeros.
    private static func isValidNameOrIPv4(_ raw: String) -> Bool {
        guard raw.count <= maxHostNameLength else { return false }
        let labels = raw.split(separator: ".", omittingEmptySubsequences: false)
        if raw.allSatisfy({ $0 == "." || $0.isNumber && $0.isASCII }) {
            return labels.count == ipv4OctetCount && labels.allSatisfy(isIPv4Octet)
        }
        return labels.allSatisfy(isDNSLabel)
    }

    private static func isDNSLabel(_ label: Substring) -> Bool {
        guard !label.isEmpty, label.count <= maxHostLabelLength,
            label.first != "-", label.last != "-"
        else { return false }
        return label.allSatisfy { char in
            char.isLetter && char.isASCII || char.isNumber && char.isASCII
                || char == "-" || char == "_"
        }
    }

    private static func isIPv4Octet(_ octet: Substring) -> Bool {
        guard !octet.isEmpty, octet.count <= maxIPv4OctetDigits, let value = Int(octet), value <= maxIPv4OctetValue
        else { return false }
        return octet.count == 1 || octet.first != "0"
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
        _ record: SyncedBackendRecord,
        to existing: StoredConnection
    ) -> StoredConnection {
        var updated = StoredConnection(
            id: existing.id,
            server: PairedServer(
                hosts: PersistenceManager.mergeHostLists(
                    existing: candidateHosts(of: record),
                    incoming: existing.server.hosts
                ),
                port: record.port,
                name: existing.server.name,
                pairedAt: existing.server.pairedAt,
                certFingerprint: fingerprintOrNil(record) ?? existing.server.certFingerprint,
                tcAddress: record.tcAddress ?? existing.server.tcAddress
            ),
            token: record.token,
            displayName: displayName(for: record),
            lastConnectedAt: existing.lastConnectedAt,
            syncUpdatedAt: record.updatedAt
        )
        // The shared owner row supplies no identity. Retain only the
        // classification previously verified on this device; live authority
        // still comes from admission of the current socket.
        updated.principal = existing.principal
        updated.localPairingSyncClock = existing.localPairingSyncClock
        updated.pendingRoutePublication = existing.pendingRoutePublication
        return updated
    }

    private static func makeConnection(from record: SyncedBackendRecord, now: Date)
        -> StoredConnection {
        let name = displayName(for: record)
        return StoredConnection(
            server: PairedServer(
                hosts: candidateHosts(of: record),
                port: record.port,
                name: name,
                pairedAt: now,
                certFingerprint: fingerprintOrNil(record),
                tcAddress: record.tcAddress
            ),
            token: record.token,
            displayName: name,
            syncUpdatedAt: record.updatedAt
        )
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
    /// A prerequisite read/migration failed; no merge or removal was committed.
    var registryReadError: ConnectionRegistryReadError?
    /// True when the merge was skipped because the saved-connections blob
    /// exists but could not be decoded; nothing was written so the original
    /// blob is preserved (intent-hq/ios#265).
    var registryUndecodable: Bool { registryReadError == .malformed }
    var changed: Bool { !(addedIds.isEmpty && updatedIds.isEmpty && removedIds.isEmpty) }
}
