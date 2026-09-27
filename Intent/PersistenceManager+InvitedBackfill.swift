import Foundation

extension PersistenceManager {
    func clearInvitedTunnelRoute(id: UUID) -> Bool {
        guard var records = loadConnectionsWithOutcome().connections,
              let index = records.firstIndex(where: { $0.id == id }), records[index].invitedPersonKey != nil else { return false }
        let record = Self.invitedRecord(records[index])
        guard records[index].server.tcAddress != nil || record?.object["tcUpdatedAt"] is NSNull else { return true }
        let server = records[index].server
        records[index].server = PairedServer(
            hosts: server.hosts, port: server.port, name: server.name, pairedAt: server.pairedAt, certFingerprint: server.certFingerprint, tcAddress: nil
        )
        queueInvitedRoutePublication(&records[index], newRoute: nil, routeObserved: true)
        guard saveConnectionsLocked(records) else { return false }
        publishPendingInvitedSessions()
        return true
    }

    /// A saved pre-v2 credential is classified only after pinned admission.
    /// Its original pairing clock survives: reconnect is never a new intent.
    func backfillInvited(_ connection: inout StoredConnection) {
        guard invitedJournalAvailable, connection.invitedSyncPayload == nil,
              let key = connection.invitedPersonKey, var record = Self.legacyInvitedRecord(connection),
              let registry = invitedRegistry, let snapshot = registry.read(), !snapshot.removalStateUnknown,
              !snapshot.frozen(key), !snapshot.records.contains(where: { $0.personKey == key }) else { return }
        var journal = invitedJournal
        journal.observe(snapshot.records)
        if record.pairedAt == 0, (journal.floors[key] ?? 0) == 0 {
            guard let initial = try? journal.nextClock(now: Date()) else { return }
            record.object["pairedAt"] = initial
            record.object["updatedAt"] = initial
        }
        invitedJournal = journal
        connection.invitedSyncPayload = record.data
        connection.pendingSyncUpdatedAt = record.updatedAt
        connection.localPairingSyncClock = record.pairedAt
    }

    /// Authenticated local provenance remains usable for removal and routing
    /// even when cloud reads or the first v2 publication have not succeeded.
    static func legacyInvitedRecord(_ connection: StoredConnection) -> InvitedSyncRecord? {
        guard let principal = connection.principal, !principal.isOwner,
              let savedPin = connection.server.certFingerprint, let pin = try? InvitedSyncKey.fingerprint(savedPin) else { return nil }
        let server = connection.server
        let millisecondsPerSecond: Double = 1000
        let clock = floor(server.pairedAt.timeIntervalSince1970 * millisecondsPerSecond)
        let updated = connection.pendingSyncUpdatedAt ?? connection.syncUpdatedAt ?? clock
        guard ConnectionPrincipal.validClock(clock), ConnectionPrincipal.validClock(updated),
              let host = server.hosts.first ?? server.tcAddress else { return nil }
        let legacy = SyncedBackendRecord(
            label: connection.displayName,
            host: host,
            hosts: server.hosts,
            port: server.port,
            fingerprint: pin,
            hostname: nil,
            detectHosts: true,
            token: connection.token,
            updatedAt: updated,
            deleted: false,
            deletedAt: nil,
            tcAddress: server.tcAddress
        )
        let candidate = InvitedLegacyMigration.Candidate(
            account: legacy.accountKey, object: ["pairedAt": clock], legacy: legacy, principalId: principal.id, fingerprint: pin
        )
        return InvitedLegacyMigration.session(candidate, principal: principal)
    }
}
