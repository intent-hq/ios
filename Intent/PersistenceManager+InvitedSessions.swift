import Foundation

extension PersistenceManager {
    private static let invitedJournalKey = "invitedSessionSyncJournal"

    var invitedJournalAvailable: Bool {
        guard let data = defaults.data(forKey: Self.invitedJournalKey) else { return true }
        return (try? JSONDecoder().decode(InvitedSyncJournal.self, from: data)) != nil
    }

    var invitedJournal: InvitedSyncJournal {
        get {
            guard let data = defaults.data(forKey: Self.invitedJournalKey),
                  let value = try? JSONDecoder().decode(InvitedSyncJournal.self, from: data) else { return InvitedSyncJournal() }
            return value
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.invitedJournalKey) }
        }
    }

    /// Refuse migration/alias changes if the local provenance write was rejected.
    /// Readback confirms acceptance by the injected/defaults store, not an fsync.
    func persistInvitedMigrationJournal(_ journal: InvitedSyncJournal) -> Bool {
        guard invitedJournalAvailable, let data = try? JSONEncoder().encode(journal) else { return false }
        defaults.set(data, forKey: Self.invitedJournalKey)
        return defaults.data(forKey: Self.invitedJournalKey) == data
    }

    enum InvitedPersistenceError: LocalizedError {
        case syncUnavailable

        var errorDescription: String? {
            "Saved shared-host access could not be checked. Unlock this device and try pairing again. Existing connections were kept."
        }
    }

    /// Called only after explicit pairing and authoritative identity discovery.
    /// A successful full read is required before a new intent can beat removals.
    func prepareInvitedPairing(_ connection: inout StoredConnection, hostname: String? = nil) throws {
        guard let principal = connection.principal, !principal.isOwner else { return }
        guard invitedJournalAvailable, let key = connection.invitedPersonKey, let pin = connection.server.certFingerprint,
              let locals = loadConnectionsWithOutcome().connections else { throw InvitedPersistenceError.syncUnavailable }
        var journal = invitedJournal
        let localRecords = locals.compactMap(Self.invitedRecord)
        journal.observe(localRecords)
        var remote: [InvitedSyncRecord] = []
        if let invitedRegistry, invitedRegistry.enabled {
            guard let snapshot = invitedRegistry.read(), !snapshot.removalStateUnknown, !snapshot.frozen(key) else {
                throw InvitedPersistenceError.syncUnavailable
            }
            journal.observe(snapshot.records)
            remote = snapshot.records.filter { $0.personKey == key }
        } else if (journal.floors[key] ?? 0) > 0 {
            throw InvitedPersistenceError.syncUnavailable
        }
        let predecessors = localRecords.filter { $0.personKey == key } + remote
        let previous = InvitedSyncMerge.person(predecessors, rememberedFloor: journal.floors[key] ?? 0)
        let clock = try journal.nextClock(now: Date())
        invitedJournal = journal
        let host = connection.server.hosts.first ?? connection.server.tcAddress
        guard let host else { throw InvitedSyncKey.Invalid.input }
        var object = previous?.object ?? [:]
        let route: Any = connection.server.tcAddress as Any? ?? previous?.object["tcAddress"] ?? NSNull()
        let routeClock: Any = connection.server.tcAddress == nil ? previous?.object["tcUpdatedAt"] ?? NSNull() : clock
        let pairing: [String: Any] = [
            "v": 2, "kind": "session", "fingerprint": try InvitedSyncKey.fingerprint(pin), "principalId": principal.id,
            "label": connection.displayName, "login": principal.login as Any? ?? NSNull(),
            "host": host, "hosts": connection.server.hosts, "port": connection.server.port,
            "token": connection.token, "updatedAt": clock, "pairedAt": clock,
            "removedThrough": journal.floors[key] ?? 0, "deleted": false, "deletedAt": NSNull()
        ]
        object.merge(pairing) { _, new in new }
        object["hostname"] = hostname as Any? ?? previous?.object["hostname"] ?? NSNull()
        object["detectHosts"] = previous?.object["detectHosts"] ?? true
        object["tcAddress"] = route
        object["tcUpdatedAt"] = routeClock
        object["legacyAccounts"] = previous?.legacyAccounts ?? []
        let record = InvitedSyncRecord(object: object, account: key)
        guard let data = record.data, InvitedSyncRecord.parse(account: key, data: data) != nil else { throw InvitedSyncKey.Invalid.input }
        connection.invitedSyncPayload = data
        connection.pendingSyncUpdatedAt = clock
        connection.localPairingSyncClock = clock
    }

    static func invitedRecord(_ connection: StoredConnection) -> InvitedSyncRecord? {
        guard let key = connection.invitedPersonKey else { return nil }
        guard let data = connection.invitedSyncPayload else { return legacyInvitedRecord(connection) }
        return InvitedSyncRecord.parse(account: key, data: data)
    }

    static func invitedTunnelAddress(_ connection: StoredConnection, fallback: String?) -> String? {
        if let record = invitedRecord(connection), record.routeClock >= 0 { return record.object["tcAddress"] as? String }
        return connection.server.tcAddress ?? fallback
    }

    /// Every attempt begins by folding removals, including observed future
    /// pairing/route clocks. Failure never acknowledges or restamps the intent.
    func publishPendingInvitedSessions() {
        guard invitedJournalAvailable, let registry = invitedRegistry, let snapshot = registry.read(), !snapshot.removalStateUnknown,
              var connections = loadConnectionsWithOutcome().connections else { return }
        var journal = invitedJournal
        journal.observe(snapshot.records + connections.compactMap(Self.invitedRecord))
        journal.reconcileLegacySources(snapshot)
        guard persistInvitedMigrationJournal(journal) else { return }
        guard publishInvitedRemovals(registry, journal: journal) else { return }
        var changed = false
        for index in connections.indices {
            guard let local = Self.invitedRecord(connections[index]), !snapshot.frozen(local.account),
                  let merged = InvitedSyncMerge.person(
                    [local] + snapshot.records.filter { $0.personKey == local.personKey },
                    rememberedFloor: journal.floors[local.account] ?? 0
                  ) else { continue }
            if !merged.live || merged.token != connections[index].token || merged.pairedAt != local.pairedAt { continue }
            // A route patch merges with remote credentials before publication.
            if registry.writeMutable(merged, snapshot: snapshot) {
                connections[index].invitedSyncPayload = merged.data
                connections[index].pendingSyncUpdatedAt = nil
                changed = true
            }
        }
        if changed { saveConnectionsLocked(connections) }
        restoreInvitedAliases(registry, journal: journal)
    }

    private func publishInvitedRemovals(_ registry: InvitedSessionRegistry, journal: InvitedSyncJournal) -> Bool {
        for (account, data) in journal.removals {
            guard let removal = InvitedSyncRecord.parse(account: account, data: data), registry.insertRemoval(removal) else { return false }
            // Inserting the immutable removal changes the registry signature.
            // Re-read both groups before repair, including any concurrent re-pair
            // or removal, while retaining writeMutable's final snapshot guard.
            guard let snapshot = registry.read(), !snapshot.removalStateUnknown else { return false }
            var observed = invitedJournal
            observed.observe(snapshot.records)
            guard persistInvitedMigrationJournal(observed) else { return false }
            guard let key = removal.personKey, !snapshot.frozen(key) else { continue }
            let existing = snapshot.records.filter { $0.personKey == removal.personKey }
            // A later authenticated re-pair is kept; the independent removal stays.
            if let merged = InvitedSyncMerge.person(existing + [removal], rememberedFloor: observed.floors[key] ?? 0), !merged.live {
                guard registry.writeMutable(merged, snapshot: snapshot) else { return false }
            }
        }
        return true
    }

    func restoreInvitedAliases(_ registry: InvitedSessionRegistry, journal: InvitedSyncJournal) {
        guard let durable = registry.read(), !durable.removalStateUnknown else { return }
        for (alias, people) in journal.retired {
            guard !journal.hasPendingLegacy(alias: alias),
                  people.allSatisfy({ key in durable.records.contains(where: { $0.personKey == key }) }) else { continue }
            let marker = InvitedSyncRecord(object: ["v": 2, "kind": "legacy-alias", "personKeys": people], account: alias)
            _ = registry.writeMutable(marker, snapshot: durable)
        }
    }

    /// Local suppression precedes credential deletion and cloud insertion.
    /// Retries reuse this exact UUID, floor and alias snapshot after relaunch.
    func rememberInvitedRemoval(_ connection: StoredConnection) -> Bool {
        guard invitedJournalAvailable, let local = Self.invitedRecord(connection), let key = local.personKey else { return false }
        var journal = invitedJournal
        if journal.removals.contains(where: { account, data in
            guard let removal = InvitedSyncRecord.parse(account: account, data: data) else { return false }
            return removal.personKey == key && removal.floor >= local.pairedAt
        }) { return true }
        var records = loadConnections().compactMap(Self.invitedRecord)
        if let snapshot = invitedRegistry?.read(), !snapshot.removalStateUnknown { records += snapshot.records }
        journal.observe(records)
        guard let clock = try? journal.nextClock(now: Date()) else { return false }
        let aliases = InvitedSyncKey.sorted(records.filter { $0.personKey == key }.flatMap(\.legacyAccounts))
        let removalId = UUID().uuidString.lowercased()
        guard let account = try? InvitedSyncKey.removal(
            fingerprint: local.fingerprint, principalId: local.principalId, removalId: removalId, removedThrough: clock, legacyAccounts: aliases
        ) else { return false }
        let removal = InvitedSyncRecord(object: [
            "v": 2, "kind": "removal", "fingerprint": local.fingerprint, "principalId": local.principalId,
            "removalId": removalId, "removedThrough": clock, "legacyAccounts": aliases
        ], account: account)
        guard let data = removal.data else { return false }
        journal.removals[account] = data
        journal.observe([removal])
        invitedJournal = journal
        return true
    }

    func queueInvitedRoutePublication(_ connection: inout StoredConnection, newRoute: String?, routeObserved: Bool = false) {
        guard invitedJournalAvailable, var record = Self.invitedRecord(connection), let key = record.personKey else { return }
        var journal = invitedJournal
        journal.observe([record])
        if let snapshot = invitedRegistry?.read(), !snapshot.removalStateUnknown { journal.observe(snapshot.records) }
        guard record.pairedAt > (journal.floors[key] ?? 0), let clock = try? journal.nextClock(now: Date()) else { return }
        invitedJournal = journal
        record.object["hosts"] = connection.server.hosts
        record.object["updatedAt"] = clock
        if newRoute != nil || routeObserved {
            record.object["tcAddress"] = newRoute as Any? ?? NSNull()
            record.object["tcUpdatedAt"] = clock
        }
        connection.invitedSyncPayload = record.data
        connection.pendingSyncUpdatedAt = clock
    }

    func queueInvitedDisplayNamePublication(_ connection: inout StoredConnection, displayName: String) {
        guard invitedJournalAvailable, var record = Self.invitedRecord(connection), let key = record.personKey,
              record.object["hostname"] as? String != displayName else { return }
        var journal = invitedJournal
        journal.observe([record])
        if let snapshot = invitedRegistry?.read(), !snapshot.removalStateUnknown { journal.observe(snapshot.records) }
        guard record.pairedAt > (journal.floors[key] ?? 0), let clock = try? journal.nextClock(now: Date()) else { return }
        invitedJournal = journal
        record.object["hostname"] = displayName
        record.object["updatedAt"] = clock
        connection.invitedSyncPayload = record.data
        connection.pendingSyncUpdatedAt = clock
    }
}
