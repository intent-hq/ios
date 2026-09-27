import Foundation

extension PersistenceManager {
    typealias InvitedAuthenticator = (StoredConnection) async throws -> ConnectionPrincipal

    /// All reads and removal folding precede authentication and writes. The
    /// caller supplies isolated connections; no owner-side socket is borrowed.
    func refreshInvitedSessions(authenticate: InvitedAuthenticator) async -> InvitedImportOutcome {
        guard invitedJournalAvailable, !invitedRefreshInProgress else { return InvitedImportOutcome() }
        invitedRefreshInProgress = true
        defer { invitedRefreshInProgress = false }
        guard let registry = invitedRegistry, let snapshot = registry.read(), !snapshot.removalStateUnknown,
              let initial = loadConnectionsWithOutcome().connections else { return InvitedImportOutcome() }
        var journal = invitedJournal
        journal.observe(snapshot.records + initial.compactMap(Self.invitedRecord))
        invitedJournal = journal
        let migrated = await migrateInvited(snapshot: snapshot, authenticate: authenticate)
        var records = snapshot.records + migrated + loadConnections().compactMap(Self.invitedRecord)
        records += invitedJournal.removals.compactMap { InvitedSyncRecord.parse(account: $0.key, data: $0.value) }
        let groups = Dictionary(grouping: records.filter { $0.personKey != nil }) { $0.personKey ?? "" }
        for key in groups.keys.sorted() {
            guard !Task.isCancelled, !snapshot.frozen(key),
                  let group = groups[key], let record = InvitedSyncMerge.person(group, rememberedFloor: invitedJournal.floors[key] ?? 0),
                  record.live, let connection = Self.connection(fromInvited: record) else { continue }
            do {
                let principal = try await authenticate(connection)
                guard !Task.isCancelled, !principal.isOwner, ConnectionPrincipal.samePerson(principal.id, record.principalId),
                      let current = refreshedInvitedRecord(record, migrated: migrated, original: snapshot),
                      var imported = Self.connection(fromInvited: current) else { continue }
                imported.principal = principal
                let outcome = upsertConnectionWithOutcome(imported)
                guard outcome.persisted else { continue }
            } catch { continue }
        }
        let removed = applyInvitedRemovalFloors()
        publishPendingInvitedSessions()
        return InvitedImportOutcome(before: initial, after: loadConnectionsWithOutcome(), suppressed: removed)
    }

    /// Authentication is an async boundary. Only the credential just checked
    /// may be installed, with freshly merged route/metadata and removal state.
    private func refreshedInvitedRecord(
        _ authenticated: InvitedSyncRecord, migrated: [InvitedSyncRecord], original: InvitedSessionRegistry.Snapshot
    ) -> InvitedSyncRecord? {
        guard invitedJournalAvailable, let key = authenticated.personKey,
              let fresh = invitedRegistry?.read(), !fresh.removalStateUnknown, !fresh.frozen(key),
              let locals = loadConnectionsWithOutcome().connections else { return nil }
        guard !locals.contains(where: { $0.invitedPersonKey == key && $0.invitedSyncPayload != nil && Self.invitedRecord($0) == nil }) else { return nil }
        var records = fresh.records + locals.compactMap(Self.invitedRecord)
        var journal = invitedJournal
        journal.observe(records)
        invitedJournal = journal
        // Prepared migrations are not durable yet. Observe fresh removals now,
        // but let publication retire aliases only after the local save succeeds.
        if fresh.hasSameEntries(as: original) { records += migrated }
        guard let merged = InvitedSyncMerge.person(records.filter { $0.personKey == key }, rememberedFloor: journal.floors[key] ?? 0),
              merged.live, merged.token == authenticated.token, merged.pairedAt == authenticated.pairedAt else { return nil }
        return merged
    }

    private func applyInvitedRemovalFloors() -> [UUID] {
        guard let connections = loadConnectionsWithOutcome().connections else { return [] }
        let floors = invitedJournal.floors
        let removed = connections
            .filter { connection in
                guard let record = Self.invitedRecord(connection) else { return false }
                return record.pairedAt <= (floors[record.account] ?? 0)
            }
            .map(\.id)
        if !removed.isEmpty {
            // Return suppressed IDs even on a failed credential save: windows
            // must stop serving a person once their removal has been observed.
            saveConnectionsLocked(connections.filter { !removed.contains($0.id) })
        }
        return removed
    }

    static func connection(fromInvited record: InvitedSyncRecord) -> StoredConnection? {
        guard record.live, let port = record.object["port"] as? Int else { return nil }
        let hosts = (record.object["hosts"] as? [String] ?? []).compactMap(SyncedBackendConnectionMerge.usableHost)
        let route = record.object["tcAddress"] as? String
        guard !hosts.isEmpty || route != nil else { return nil }
        let millisecondsPerSecond: Double = 1000
        var result = StoredConnection(
            server: PairedServer(
                hosts: hosts,
                port: port,
                name: "Intent",
                pairedAt: Date(timeIntervalSince1970: record.pairedAt / millisecondsPerSecond),
                certFingerprint: record.fingerprint,
                tcAddress: route
            ),
            token: record.token,
            displayName: record.object["label"] as? String,
            syncUpdatedAt: record.updatedAt
        )
        result.invitedSyncPayload = record.data
        return result
    }

    private func migrateInvited(snapshot: InvitedSessionRegistry.Snapshot, authenticate: InvitedAuthenticator) async -> [InvitedSyncRecord] {
        let candidates = InvitedLegacyMigration.candidates(snapshot, journal: invitedJournal)
        // Reserve every eligible source before any await or peer save can retire
        // their shared alias. This grants retry of the row, never socket authority.
        var journal = invitedJournal
        journal.reserveLegacySources(candidates)
        invitedJournal = journal
        let ambiguous = Set(candidates.filter { $0.legacy.deleted && $0.principalId == nil }.map(\.account))
        var prepared: [InvitedSyncRecord] = []
        // Authenticate all attributable live candidates before selecting v1 LWW
        // winners. Row ordering cannot turn a missing-person deletion into C.
        for candidate in candidates where !ambiguous.contains(candidate.account) && !candidate.legacy.deleted {
            guard !Task.isCancelled else { return [] }
            let legacy = candidate.legacy
            let connection = StoredConnection(
                server: PairedServer(
                    hosts: SyncedBackendConnectionMerge.candidateHosts(of: legacy),
                    port: legacy.port,
                    name: legacy.label,
                    pairedAt: Date(),
                    certFingerprint: candidate.fingerprint,
                    tcAddress: legacy.tcAddress
                ),
                token: legacy.token
            )
            guard let principal = try? await authenticate(connection),
                  let record = InvitedLegacyMigration.session(candidate, principal: principal),
                  !snapshot.frozen(record.account),
                  !snapshot.records.contains(where: { $0.personKey == record.personKey }), invitedJournalAvailable else { continue }
            journal = invitedJournal
            guard journal.bindLegacySource(candidate, personKey: record.account) else { continue }
            invitedJournal = journal
            guard journal.floors[record.account] == nil else { continue }
            prepared.append(record)
        }
        return selectLegacyWinners(prepared, candidates: candidates, ambiguous: ambiguous)
    }

    private func selectLegacyWinners(
        _ prepared: [InvitedSyncRecord], candidates: [InvitedLegacyMigration.Candidate], ambiguous: Set<String>
    ) -> [InvitedSyncRecord] {
        let groups = Dictionary(grouping: prepared, by: \.account)
        var result: [InvitedSyncRecord] = []
        for (key, live) in groups {
            let deletes = candidates.filter { $0.personKey == key && $0.legacy.deleted && !ambiguous.contains($0.account) }
            let newestLive = live.map(\.updatedAt).max() ?? 0
            let newestDelete = deletes.max { $0.legacy.updatedAt < $1.legacy.updatedAt }
            if let deletion = newestDelete, deletion.legacy.updatedAt >= newestLive {
                if let removal = rememberLegacyRemoval(deletion, aliases: live.flatMap(\.legacyAccounts) + deletes.map(\.account)) { result.append(removal) }
                continue
            }
            guard var merged = live.max(by: { lhs, rhs in
                lhs.updatedAt == rhs.updatedAt ? lhs.routeAccount.utf8.lexicographicallyPrecedes(rhs.routeAccount.utf8) : lhs.updatedAt < rhs.updatedAt
            }) else { continue }
            if merged.pairedAt == 0 {
                var journal = invitedJournal
                guard let clock = try? journal.nextClock(now: Date()), (journal.floors[key] ?? 0) == 0 else { continue }
                merged.object["pairedAt"] = clock
                merged.object["updatedAt"] = clock
                invitedJournal = journal
            }
            merged.object["legacyAccounts"] = InvitedSyncKey.sorted(live.flatMap(\.legacyAccounts) + deletes.map(\.account))
            // Retirement is installed only after this candidate is persisted and
            // published by the ordinary invited pass.
            result.append(merged)
        }
        for deletion in candidates where deletion.legacy.deleted && deletion.principalId != nil && !ambiguous.contains(deletion.account) {
            guard let key = deletion.personKey, groups[key] == nil else { continue }
            if let removal = rememberLegacyRemoval(deletion, aliases: [deletion.account]) { result.append(removal) }
        }
        return result
    }

    private func rememberLegacyRemoval(_ candidate: InvitedLegacyMigration.Candidate, aliases: [String]) -> InvitedSyncRecord? {
        guard let principalId = candidate.principalId, let key = candidate.personKey else { return nil }
        var journal = invitedJournal
        let floor = max(1, candidate.legacy.updatedAt)
        if let existing = journal.removals.compactMap({ InvitedSyncRecord.parse(account: $0.key, data: $0.value) })
            .first(where: { $0.personKey == key && $0.floor >= floor }) { return existing }
        let removalId = UUID().uuidString.lowercased()
        let aliases = InvitedSyncKey.sorted(aliases)
        guard let account = try? InvitedSyncKey.removal(
            fingerprint: candidate.fingerprint, principalId: principalId, removalId: removalId, removedThrough: floor, legacyAccounts: aliases
        ) else { return nil }
        let record = InvitedSyncRecord(object: [
            "v": 2, "kind": "removal", "fingerprint": candidate.fingerprint, "principalId": principalId,
            "removalId": removalId, "removedThrough": floor, "legacyAccounts": aliases
        ], account: account)
        guard let data = record.data else { return nil }
        journal.removals[account] = data
        journal.observe([record])
        invitedJournal = journal
        return record
    }
}
