import Foundation

extension ConnectionManager {
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
        guard connectionState == .connected, let token, let port else { return }
        let myGeneration = connectionGeneration

        // Refresh the stored display name first: it must run even when the
        // localIps flow below bails out (older daemon, transport hiccup).
        await refreshStoredDisplayName(token: token, port: port)

        let response: Result<Any, Error>
        do {
            response = .success(try await request("system.status"))
        } catch {
            response = .failure(error)
        }
        switch Self.hostRouteRefreshDecision(
            response: response,
            requestedGeneration: myGeneration,
            currentGeneration: connectionGeneration
        ) {
        case .failed:
            AppLog.connection.debug("[ConnectionManager] Host route refresh: system.status failed (skipping)")
        case .stale:
            break
        case let .current(localIps, reportedTc):
            applyReportedTunnelAddress(reportedTc, token: token, port: port)
            applyReportedHosts(localIps, token: token, port: port)
        }
    }

    private func applyReportedTunnelAddress(_ reportedTc: String?, token: String, port: Int) {
        if let reportedTc, reportedTc != tcAddress {
            AppLog.connection.debug("[ConnectionManager] Host route refresh: tcAddress updated")
            applyRefreshedTunnelAddress(reportedTc)
        }

        // The active connection, verified against the live token + port
        // (same record-matching rules as the host persistence below).
        if let reportedTc,
            let stored = PersistenceManager.shared.activeConnection(),
            stored.token == token, stored.server.port == port,
            stored.server.tcAddress != reportedTc {
            if !PersistenceManager.shared.updateConnectionTcAddress(
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
        if let stored = PersistenceManager.shared.activeConnection(),
            stored.token == token, stored.server.port == port {
            let persistedHosts = Self.mergeHosts(existing: stored.server.hosts, reported: merged)
            if stored.server.hosts != persistedHosts {
                if !PersistenceManager.shared.updateConnectionHosts(
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
    private func refreshStoredDisplayName(token: String, port: Int) async {
        let myGeneration = connectionGeneration
        guard let result = try? await request("host.status"),
              let name = ConnectionPairing.displayName(fromHostStatus: result) else {
            return
        }

        // A newer connect() may have superseded us while the RPC was in flight.
        guard connectionGeneration == myGeneration else { return }

        if let stored = PersistenceManager.shared.activeConnection(),
            stored.token == token, stored.server.port == port,
            stored.displayName != name {
            AppLog.connection.debug("[ConnectionManager] Display name refresh: \(stored.displayName) -> \(name)")
            if !PersistenceManager.shared.updateConnectionDisplayName(
                id: stored.id,
                displayName: name
            ) {
                AppLog.connection.warning("[ConnectionManager] Could not persist refreshed display name")
            }
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
    /// reported IPs not already present are appended, deduped. Reported values
    /// are untrusted and must be valid URL host components; raw IPv6 literals
    /// are bracket-normalized before they can be raced or persisted.
    static func mergeHosts(existing: [String], reported: [String]) -> [String] {
        var merged = existing
        var seen = Set(existing)
        for ipAddress in reported {
            let trimmed = ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let host = SyncedBackendConnectionMerge.usableHost(trimmed),
                  !seen.contains(host) else { continue }
            merged.append(host)
            seen.insert(host)
        }
        return merged
    }
}
