import Foundation

/// One membership refresh: the request task and the principal it must keep.
/// The principal fences a later event while `currentPrincipal` is cleared.
struct AuthorityRefresh {
    let previous: ConnectionPrincipal?
    let task: Task<Void, Never>
}

extension ConnectionManager {
    func finishIdentityAdmission(_ handshake: ConnectionHandshake, token: String, fingerprint: String?) {
        let principal = handshake.principal
        scriptMonitorsDisabledForConnection = false
        currentPrincipal = principal
        lastConnectedPrincipal = principal
        admission = ConnectionAdmission(id: UUID(), token: token, fingerprint: fingerprint, principal: principal)
        capabilities = handshake.capabilities
        bindSavedIdentity(principal)
        connectionState = .connected
    }

    func clearPrincipal() {
        currentPrincipal = nil
        admission = nil
        capabilities = .unknown
        scriptMonitorsDisabledForConnection = false
        authorityRefresh?.task.cancel()
        authorityRefresh = nil
        pendingAuthorityRevision = -1
    }

    func disableScriptMonitors() {
        scriptMonitorsDisabledForConnection = true
        capabilities = capabilities.disablingScriptMonitors()
    }

    /// A saved record can constrain identity, never supply current authority.
    func validateIdentity(_ principal: ConnectionPrincipal, token: String, fingerprint: String?) throws {
        guard persistence.invitedJournalAvailable else { throw PersistenceManager.InvitedPersistenceError.syncUnavailable }
        let records = persistence.loadConnections().filter { $0.token == token && InvitedSyncKey.sameFingerprint($0.server.certFingerprint, fingerprint) }
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
        guard let admission, let port, var records = persistence.loadConnectionsWithOutcome().connections else { return }
        let token = admission.token
        var changed = false
        for index in records.indices where records[index].token == token && records[index].server.port == port
            && InvitedSyncKey.sameFingerprint(records[index].server.certFingerprint, admission.fingerprint) {
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
        let previous = currentPrincipal ?? authorityRefresh?.previous
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
        lastConnectedPrincipal = nil
        capabilities = .unknown
        authorityRefresh?.task.cancel()
        let generation = connectionGeneration
        let currentSocket = socket
        let task = Task { [weak self] in
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
                lastConnectedPrincipal = principal
                if let previous = admission {
                    admission = ConnectionAdmission(id: previous.id, token: previous.token, fingerprint: previous.fingerprint, principal: principal)
                }
                let negotiated = ConnectionCapabilities(hello: hello)
                capabilities = scriptMonitorsDisabledForConnection ? negotiated.disablingScriptMonitors() : negotiated
                pendingAuthorityRevision = -1
                authorityRefresh = nil
                bindSavedIdentity(principal)
            } catch {
                guard !Task.isCancelled, connectionGeneration == generation, socket === currentSocket else { return }
                if ConnectionPrincipal.isRevocation(error) { rememberCurrentPersonRevoked() }
                disconnect()
            }
        }
        authorityRefresh = AuthorityRefresh(previous: previous, task: task)
    }

    func handleAuthoritativeSocketFailure(_ error: Error) -> Bool {
        guard ConnectionPrincipal.isRevocation(error) else { return false }
        rememberCurrentPersonRevoked()
        disconnect()
        return true
    }

    private func rememberCurrentPersonRevoked() {
        guard let admission else { return }
        for record in persistence.loadConnections() where record.token == admission.token && InvitedSyncKey.sameFingerprint(record.server.certFingerprint, admission.fingerprint) {
            _ = persistence.rememberInvitedRemoval(record)
        }
        persistence.publishPendingInvitedSessions()
    }

    func stopAfterIdentityFailure(_ error: Error, generation: Int) -> Bool {
        guard !Task.isCancelled, connectionGeneration == generation else { return true }
        if error is ConnectionPrincipal.AdmissionError || ConnectionPrincipal.isRevocation(error) {
            if case ConnectionPrincipal.AdmissionError.timedOut = error { return false }
            reconnectStopReason = ConnectionPrincipal.isRevocation(error)
                ? String(localized: "Your access to this Mac was removed.")
                : error.localizedDescription
            disconnect()
            return true
        }
        return false
    }

    func admit(_ winner: RacedConnection, token: String, fingerprint: String?) async throws -> ConnectionHandshake {
        let observed = persistence.loadConnections().filter { $0.token == token && InvitedSyncKey.sameFingerprint($0.server.certFingerprint, fingerprint) }
        do {
            let handshake = try await admit(winner)
            try validateIdentity(handshake.principal, token: token, fingerprint: fingerprint)
            return handshake
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
