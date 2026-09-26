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
              let principal = connection.principal, !principal.isOwner,
              let savedPin = connection.server.certFingerprint, let pin = try? InvitedSyncKey.fingerprint(savedPin), let key = connection.invitedPersonKey,
              let registry = invitedRegistry, let snapshot = registry.read(), !snapshot.removalStateUnknown,
              !snapshot.frozen(key), !snapshot.records.contains(where: { $0.personKey == key }) else { return }
        let server = connection.server
        let millisecondsPerSecond: Double = 1000
        var clock = floor(server.pairedAt.timeIntervalSince1970 * millisecondsPerSecond)
        guard ConnectionPrincipal.validClock(clock), let host = server.hosts.first ?? server.tcAddress else { return }
        var journal = invitedJournal
        journal.observe(snapshot.records)
        if clock == 0, (journal.floors[key] ?? 0) == 0 {
            guard let initial = try? journal.nextClock(now: Date()) else { return }
            clock = initial
        }
        invitedJournal = journal
        let legacy = SyncedBackendRecord(
            label: connection.displayName,
            host: host,
            hosts: server.hosts,
            port: server.port,
            fingerprint: pin,
            hostname: nil,
            detectHosts: true,
            token: connection.token,
            updatedAt: clock,
            deleted: false,
            deletedAt: nil,
            tcAddress: server.tcAddress
        )
        let candidate = InvitedLegacyMigration.Candidate(
            account: legacy.accountKey, object: ["pairedAt": clock], legacy: legacy, principalId: principal.id, fingerprint: pin
        )
        guard let record = InvitedLegacyMigration.session(candidate, principal: principal) else { return }
        connection.invitedSyncPayload = record.data
        connection.pendingSyncUpdatedAt = clock
        connection.localPairingSyncClock = clock
    }
}
