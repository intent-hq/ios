import Foundation

extension ConnectionManager {
    private struct HostRefreshContext {
        let admission: ConnectionAdmission
        let generation: Int
        let credentialsRevision: Int
    }

    enum HostRouteRefreshDecision: Equatable {
        case failed
        case stale
        case current(localIps: LocalIPsResult, tcAddress: String?)
    }

    // MARK: - Host route refresh

    /// Fire-and-forget wrapper around `refreshHostRoutes()`. Called from every
    /// successful connect path (initial connect and reconnect) so route refresh
    /// never delays the connection becoming usable.
    func scheduleHostRoutesRefresh() {
        Task { await self.refreshHostRoutes() }
    }

    /// Shared post-connect hook: queries `system.status` for the daemon's
    /// `localIps` and merges them into the known host routes — both the
    /// in-memory list used by reconnect racing and the persisted
    /// `StoredConnection` record (the active connection, verified against the
    /// live token + port; updated by record id since `upsertConnection`
    /// matches by host set + port and would duplicate the record when the
    /// host set grows).
    ///
    /// Failures are non-fatal: older daemons without `localIps` and transport
    /// errors are skipped silently and the connection proceeds unchanged.
    func refreshHostRoutes() async {
        guard connectionState == .connected, let admission, let port else { return }
        let token = admission.token
        let context = HostRefreshContext(admission: admission, generation: connectionGeneration, credentialsRevision: reconnectCredentialsRevision)
        guard hostRefreshIsCurrent(context) else { return }

        // Refresh the stored display name first: it must run even when the
        // localIps flow below bails out (older daemon, transport hiccup).
        if admission.principal.isOwner {
            await refreshStoredDisplayName(token: token, port: port, context: context)
        }
        guard hostRefreshIsCurrent(context) else { return }

        let response: Result<Any, Error>
        do {
            response = .success(try await request("system.status"))
        } catch {
            response = .failure(error)
        }
        guard hostRefreshIsCurrent(context) else { return }
        applyHostStatusResponse(response, token: token, port: port, context: context)
    }

    private func applyHostStatusResponse(_ response: Result<Any, Error>, token: String, port: Int, context: HostRefreshContext) {
        if !context.admission.principal.isOwner, case .success(let result) = response {
            persistDisplayName(from: result, token: token, port: port, shared: true)
        }
        switch Self.hostRouteRefreshDecision(
            response: response,
            requestedGeneration: context.generation,
            currentGeneration: connectionGeneration
        ) {
        case .failed:
            AppLog.connection.debug("[ConnectionManager] Host route refresh: system.status failed (skipping)")
        case .stale:
            break
        case let .current(localIps, reportedTc):
            if case .success(let value) = response, (value as? [String: Any])?["tcAddress"] is NSNull,
               let saved = savedConnection(token: token, port: port), saved.invitedPersonKey != nil {
                applyRefreshedTunnelAddress(nil)
                _ = persistence.clearInvitedTunnelRoute(id: saved.id)
            }
            applyReportedTunnelAddress(reportedTc, token: token, port: port)
            applyReportedHosts(localIps, token: token, port: port)
        }
    }

    private func hostRefreshIsCurrent(_ context: HostRefreshContext) -> Bool {
        connectionState == .connected && admission?.id == context.admission.id
            && connectionGeneration == context.generation && reconnectCredentialsRevision == context.credentialsRevision
            && token == context.admission.token && InvitedSyncKey.sameFingerprint(certFingerprint, context.admission.fingerprint)
    }

    private func applyReportedTunnelAddress(_ reportedTc: String?, token: String, port: Int) {
        if let reportedTc, reportedTc != tcAddress {
            AppLog.connection.debug("[ConnectionManager] Host route refresh: tcAddress updated")
            applyRefreshedTunnelAddress(reportedTc)
        }

        // The active connection, verified against the live token + port
        // (same record-matching rules as the host persistence below).
        if let reportedTc,
            let stored = savedConnection(token: token, port: port),
            stored.token == token, stored.server.port == port,
            stored.server.tcAddress != reportedTc {
            if !persistence.updateConnectionTcAddress(
                id: stored.id,
                tcAddress: reportedTc
            ) {
                AppLog.connection.warning("[ConnectionManager] Could not persist refreshed tunnel route")
            }
        }
    }

    private func applyReportedHosts(_ localIps: LocalIPsResult, token: String, port: Int) {
        guard case let .value(reported) = localIps, !reported.isEmpty else {
            AppLog.connection.debug("[ConnectionManager] Host route refresh: no localIps reported (skipping)")
            return
        }

        let merged = Self.mergeHosts(existing: hosts, reported: reported)
        if merged != hosts {
            AppLog.connection.debug("[ConnectionManager] Host route refresh: hosts \(hosts) -> \(merged)")
            applyRefreshedHosts(merged)
        }

        // Persist to the record we actually connected through: the active
        // connection. Token + port must match the live connection — during
        // initial pairing the active record is still the previous one (or
        // absent) until ConnectionPairing.finalize saves + activates the new
        // record and re-triggers this refresh. Matching by token + port alone
        // would be ambiguous: the same daemon can be saved as separate records
        // with different host sets at the same port.
        //
        // Merge against the STORED hosts, not just the in-memory merge: this
        // session may have connected with a narrower host list than the
        // record holds (e.g. a single-host manual re-pair while the record
        // also has a NAT hostname), and persisting the in-memory merge alone
        // would drop those hosts.
        if let stored = savedConnection(token: token, port: port),
            stored.token == token, stored.server.port == port {
            let persistedHosts = Self.mergeHosts(existing: stored.server.hosts, reported: merged)
            if stored.server.hosts != persistedHosts {
                if !persistence.updateConnectionHosts(
                    id: stored.id,
                    hosts: persistedHosts
                ) {
                    AppLog.connection.warning("[ConnectionManager] Could not persist refreshed host routes")
                }
            }
        }
    }

    static func hostRouteRefreshDecision(
        response: Result<Any, Error>,
        requestedGeneration: Int,
        currentGeneration: Int
    ) -> HostRouteRefreshDecision {
        guard case let .success(result) = response else { return .failed }
        guard requestedGeneration == currentGeneration else { return .stale }
        return .current(
            localIps: localIps(fromSystemStatus: result),
            tcAddress: tcAddress(fromSystemStatus: result)
        )
    }

    /// Refreshes the active stored connection's display name from `host.status`
    /// (prettyHostname → hostname → keep existing), so connections saved before
    /// the daemon reported a pretty name heal on the next successful connect.
    /// Same record-matching rules as the host persistence in
    /// `refreshHostRoutes()`: the active connection, verified against the live
    /// token + port. Failures are non-fatal: older daemons and transport errors
    /// are skipped silently and the existing name is kept.
    private func refreshStoredDisplayName(token: String, port: Int, context: HostRefreshContext) async {
        guard let result = try? await request("host.status") else {
            return
        }

        // A reconnect, credential import, or local route edit can supersede
        // this reply while the admitted socket remains otherwise usable.
        guard hostRefreshIsCurrent(context) else { return }
        persistDisplayName(from: result, token: token, port: port, shared: false)
    }

    private func persistDisplayName(from result: Any, token: String, port: Int, shared: Bool) {
        guard let name = ConnectionPairing.displayName(fromHostStatus: result, shared: shared) else { return }
        if let stored = savedConnection(token: token, port: port),
            stored.token == token, stored.server.port == port,
            stored.displayName != name || shared {
            AppLog.connection.debug("[ConnectionManager] Display name refreshed")
            if !persistence.updateConnectionDisplayName(
                id: stored.id,
                displayName: name
            ) {
                AppLog.connection.warning("[ConnectionManager] Could not persist refreshed display name")
            }
        }
    }

    private func savedConnection(token: String, port: Int) -> StoredConnection? {
        persistence.loadConnections().first { saved in
            saved.token == token && saved.server.port == port && InvitedSyncKey.sameFingerprint(saved.server.certFingerprint, admission?.fingerprint)
        }
    }

    /// Extracts the `localIps` array from a `system.status` result. Returns unavailable
    /// when the field is absent (older daemon) or malformed.
    static func localIps(fromSystemStatus result: Any) -> LocalIPsResult {
        guard let status = result as? [String: Any],
              let ips = status["localIps"] as? [String] else { return .unavailable }
        return .value(ips)
    }

    /// Extracts the `tcAddress` field from a `system.status` result. Returns
    /// nil when absent (older daemon, tunnel not running), malformed, or
    /// blank.
    static func tcAddress(fromSystemStatus result: Any) -> String? {
        guard let status = result as? [String: Any],
              let raw = status["tcAddress"] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Merges daemon-reported IPs into the existing host list: existing hosts
    /// (originally paired/entered) keep their order and are never dropped;
    /// reported IPs not already present are appended, deduped
    /// case-insensitively (DNS names and IPv6 hex are case-insensitive —
    /// ios#341) keeping the first spelling seen. Reported values are untrusted
    /// and must be valid URL host components; raw IPv6 literals are
    /// bracket-normalized before they can be raced or persisted.
    static func mergeHosts(existing: [String], reported: [String]) -> [String] {
        var merged = existing
        var seen = Set(existing.map(SyncedBackendConnectionMerge.normalizeHost))
        for ipAddress in reported {
            let trimmed = ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let host = SyncedBackendConnectionMerge.usableHost(trimmed) else { continue }
            let key = SyncedBackendConnectionMerge.normalizeHost(host)
            guard !seen.contains(key) else { continue }
            merged.append(host)
            seen.insert(key)
        }
        return merged
    }
}
