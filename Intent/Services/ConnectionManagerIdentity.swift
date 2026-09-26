import Foundation

extension ConnectionManager {
    func finishIdentityAdmission(_ principal: ConnectionPrincipal) {
        currentPrincipal = principal
        bindSavedIdentity(principal)
        connectionState = .connected
    }

    func clearPrincipal() {
        currentPrincipal = nil
        authorityRefreshTask?.cancel()
        authorityRefreshTask = nil
        pendingAuthorityRevision = -1
        authorityBeforeRefresh = nil
    }

    /// A saved record can constrain identity, never supply current authority.
    func validateIdentity(_ principal: ConnectionPrincipal, token: String, fingerprint: String?) throws {
        guard persistence.invitedJournalAvailable else { throw PersistenceManager.InvitedPersistenceError.syncUnavailable }
        let records = persistence.loadConnections().filter { $0.token == token && $0.server.certFingerprint == fingerprint }
        for record in records {
            if let saved = record.principal, !ConnectionPrincipal.samePerson(saved.id, principal.id) {
                throw ConnectionPrincipal.AdmissionError.personChanged
            }
            let millisecondsPerSecond: Double = 1000
            let clock = PersistenceManager.invitedRecord(record)?.pairedAt ?? record.server.pairedAt.timeIntervalSince1970 * millisecondsPerSecond
            if DiagnosticConnectContext.origin != .pairing, !principal.isOwner, let fingerprint,
               let key = try? InvitedSyncKey.session(fingerprint: fingerprint, principalId: principal.id),
               clock <= (persistence.invitedJournal.floors[key] ?? 0) {
                throw ConnectionPrincipal.AdmissionError.personChanged
            }
        }
    }

    func bindSavedIdentity(_ principal: ConnectionPrincipal) {
        guard let token, let port, var records = persistence.loadConnectionsWithOutcome().connections else { return }
        var changed = false
        for index in records.indices where records[index].token == token && records[index].server.port == port
            && records[index].server.certFingerprint == certFingerprint {
            if let saved = records[index].principal, !ConnectionPrincipal.samePerson(saved.id, principal.id) { continue }
            records[index].principal = principal
            persistence.backfillInvited(&records[index])
            changed = true
        }
        if changed { persistence.saveConnectionsLocked(records) }
    }

    /// Membership events invalidate first. A newer notification cancels this
    /// refresh; generation/socket fences prevent a late reply reviving rights.
    func invalidatePrincipalIfNeeded(method: String, params: Any) {
        guard method == "events.event" || method == "event", let envelope = params as? [String: Any] else { return }
        let event = envelope["event"] as? [String: Any] ?? envelope
        guard event["type"] as? String == "host:members-changed" else { return }
        let data = event["data"] as? [String: Any] ?? event
        let revision = ConnectionPrincipal.number(data["revision"]) ?? 0
        guard revision > max(currentPrincipal?.revision ?? -1, pendingAuthorityRevision) else { return }
        pendingAuthorityRevision = revision
        let previous = currentPrincipal ?? authorityBeforeRefresh
        authorityBeforeRefresh = previous
        if let previous, let removed = data["principalId"] as? String,
           data["action"] as? String == "removed", ConnectionPrincipal.samePerson(removed, previous.id) {
            rememberCurrentPersonRevoked()
            disconnect()
            return
        }
        refreshPrincipal(after: revision, previous: previous)
    }

    private func refreshPrincipal(after revision: Double, previous: ConnectionPrincipal?) {
        currentPrincipal = nil
        authorityRefreshTask?.cancel()
        let generation = connectionGeneration
        let currentSocket = socket
        authorityRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let hello = try await request("client.hello", params: PairingClientIdentity.parameters())
                let value = try await request("principal.me")
                let principal = try ConnectionPrincipal.parse(value, hello: hello)
                try Task.checkCancellation()
                guard connectionGeneration == generation, socket === currentSocket else { return }
                if let previous, !ConnectionPrincipal.samePerson(principal.id, previous.id) { throw ConnectionPrincipal.AdmissionError.personChanged }
                guard (principal.revision ?? -1) >= revision else { throw ConnectionPrincipal.AdmissionError.incompatible }
                currentPrincipal = principal
                pendingAuthorityRevision = -1
                authorityBeforeRefresh = nil
                bindSavedIdentity(principal)
            } catch {
                guard !Task.isCancelled, connectionGeneration == generation, socket === currentSocket else { return }
                if ConnectionPrincipal.isRevocation(error) { rememberCurrentPersonRevoked() }
                disconnect()
            }
        }
    }

    func handleAuthoritativeSocketFailure(_ error: Error) -> Bool {
        guard ConnectionPrincipal.isRevocation(error) else { return false }
        rememberCurrentPersonRevoked()
        disconnect()
        return true
    }

    private func rememberCurrentPersonRevoked() {
        for record in persistence.loadConnections() where record.token == token && record.server.certFingerprint == certFingerprint {
            _ = persistence.rememberInvitedRemoval(record)
        }
        persistence.publishPendingInvitedSessions()
    }

    func stopAfterIdentityFailure(_ error: Error, generation: Int) -> Bool {
        guard !Task.isCancelled, connectionGeneration == generation else { return true }
        if error is ConnectionPrincipal.AdmissionError || ConnectionPrincipal.isRevocation(error) {
            if case ConnectionPrincipal.AdmissionError.timedOut = error { return false }
            disconnect()
            return true
        }
        return false
    }

    func admit(_ winner: RacedConnection, token: String, fingerprint: String?) async throws -> ConnectionPrincipal {
        let observed = persistence.loadConnections().filter { $0.token == token && $0.server.certFingerprint == fingerprint }
        do {
            let principal = try await admit(winner)
            try validateIdentity(principal, token: token, fingerprint: fingerprint)
            return principal
        } catch {
            await winner.disconnect()
            if !Task.isCancelled { persistence.recordAuthoritativeRevocation(error, observed: observed) }
            throw error
        }
    }
}

extension PersistenceManager {
    /// Only the exact credential generation rejected by an authoritative RPC
    /// can create a removal. Network/Keychain/TLS failures are not revocation.
    func recordAuthoritativeRevocation(_ error: Error, observed: [StoredConnection]) {
        guard ConnectionPrincipal.isRevocation(error) else { return }
        for old in observed {
            guard let before = Self.invitedRecord(old),
                  let current = loadConnections().first(where: { $0.id == old.id }),
                  let after = Self.invitedRecord(current), before.account == after.account,
                  old.token == current.token, before.pairedAt == after.pairedAt else { continue }
            _ = rememberInvitedRemoval(current)
        }
        publishPendingInvitedSessions()
    }
}
