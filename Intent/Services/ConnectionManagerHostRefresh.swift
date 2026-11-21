import Foundation

extension ConnectionManager {
    private struct HostRefreshContext {
        let admission: ConnectionAdmission
        let generation: Int
        let credentialsRevision: Int
    }

    enum LocalIPsResult: Equatable {
        case unavailable
        case value([String])
    }

    enum HostRouteRefreshDecision: Equatable {
        case failed
        case stale
        case current(localIps: LocalIPsResult, tcAddress: String?)
    }

    // MARK: - Host route refresh

    func scheduleHostRoutesRefresh() {
        Task { await self.refreshHostRoutes() }
    }

    func refreshHostRoutes() async {
        guard connectionState == .connected, let admission, let port else { return }
        let token = admission.token
        let context = HostRefreshContext(admission: admission, generation: connectionGeneration, credentialsRevision: reconnectCredentialsRevision)
        guard hostRefreshIsCurrent(context) else { return }

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

    private func refreshStoredDisplayName(token: String, port: Int, context: HostRefreshContext) async {
        guard let result = try? await request("host.status") else {
            return
        }

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

    static func localIps(fromSystemStatus result: Any) -> LocalIPsResult {
        guard let status = result as? [String: Any],
              let ips = status["localIps"] as? [String] else { return .unavailable }
        return .value(ips)
    }

    static func tcAddress(fromSystemStatus result: Any) -> String? {
        guard let status = result as? [String: Any],
              let raw = status["tcAddress"] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

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
