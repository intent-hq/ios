import Foundation
import Network

enum SyncedBackendConnectionMerge {
    private static let millisecondsPerSecond: TimeInterval = 1000

    struct Result: Equatable {
        var connections: [StoredConnection]
        var addedIds: [UUID] = []
        var updatedIds: [UUID] = []
        var removedIds: [UUID] = []
        var changed: Bool { !(addedIds.isEmpty && updatedIds.isEmpty && removedIds.isEmpty) }
    }

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

    static func normalizeFingerprint(_ raw: String?) -> String {
        (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func normalizeHost(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func candidateHosts(of record: SyncedBackendRecord) -> [String] {
        PersistenceManager.mergeHostLists(
            existing: record.host == record.tcAddress ? [] : [record.host].compactMap(usableHost),
            incoming: record.hosts.filter { $0 != record.tcAddress }.compactMap(usableHost)
        )
    }

    nonisolated static func usableHost(_ raw: String) -> String? {
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
        guard inner.allSatisfy({ $0.isHexDigit && $0.isASCII || $0 == ":" }),
            IPv6Address(String(inner)) != nil
        else { return nil }
        return "[\(inner)]"
    }

    nonisolated private static let maxHostNameLength = 253
    nonisolated private static let maxHostLabelLength = 63
    nonisolated private static let ipv4OctetCount = 4
    nonisolated private static let maxIPv4OctetDigits = 3
    nonisolated private static let maxIPv4OctetValue = 255

    nonisolated private static func isValidNameOrIPv4(_ raw: String) -> Bool {
        guard raw.count <= maxHostNameLength else { return false }
        let labels = raw.split(separator: ".", omittingEmptySubsequences: false)
        if raw.allSatisfy({ $0 == "." || $0.isNumber && $0.isASCII }) {
            return labels.count == ipv4OctetCount && labels.allSatisfy(isIPv4Octet)
        }
        return labels.allSatisfy(isDNSLabel)
    }

    nonisolated private static func isDNSLabel(_ label: Substring) -> Bool {
        guard !label.isEmpty, label.count <= maxHostLabelLength,
            label.first != "-", label.last != "-"
        else { return false }
        return label.allSatisfy { char in
            char.isLetter && char.isASCII || char.isNumber && char.isASCII
                || char == "-" || char == "_"
        }
    }

    nonisolated private static func isIPv4Octet(_ octet: Substring) -> Bool {
        guard !octet.isEmpty, octet.count <= maxIPv4OctetDigits, let value = Int(octet), value <= maxIPv4OctetValue
        else { return false }
        return octet.count == 1 || octet.first != "0"
    }

    static func displayName(for record: SyncedBackendRecord) -> String {
        for candidate in [record.label, record.hostname ?? ""] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "\(record.host):\(record.port)"
    }

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

struct SyncedBackendMergeOutcome: Equatable {
    var addedIds: [UUID]
    var updatedIds: [UUID]
    var removedIds: [UUID]
    var removedActiveConnection: Bool
    var registryReadError: ConnectionRegistryReadError?
    var registryUndecodable: Bool { registryReadError == .malformed }
    var changed: Bool { !(addedIds.isEmpty && updatedIds.isEmpty && removedIds.isEmpty) }
}
