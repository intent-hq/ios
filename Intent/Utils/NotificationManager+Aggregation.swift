import Foundation

extension NotificationManager {
    private struct IdleEventDictionary {
        let event: [String: Any]
    }

    private struct IdleEventContext {
        let agentId: String
        let workspaceId: String
        let agentName: String
        let connectionId: UUID
    }

    // MARK: - Cross-session aggregation

    /// Observe a backend session's connection so its agents alert too.
    /// Attaching a transient pairing session (no backend) or an
    /// already-observed backend is a no-op. Wired to
    /// `BackendSessionRegistry.onSessionCreated`.
    func attachSessionObserver(for session: BackendSession) {
        guard let backendID = session.backendID else { return }
        guard observedSessions[backendID] == nil else { return }
        let handlerId = session.connection.onEvent { [weak self] _, params in
            Task { @MainActor in
                self?.handleEvent(params, from: backendID)
            }
        }
        observedSessions[backendID] = (session, handlerId)
    }

    /// Stop observing a backend session's connection. Wired to
    /// `BackendSessionRegistry.onSessionTeardown`; extra detaches are no-ops.
    func detachSessionObserver(for backendID: BackendID) {
        guard let observed = observedSessions.removeValue(forKey: backendID) else { return }
        observed.session.connection.removeEventHandler(id: observed.handlerId)
    }

    func handleEvent(_ params: Any, from sourceBackendID: BackendID?) {
        guard let context = idleEventContext(params, sourceBackendID: sourceBackendID) else { return }

        // Fresh agent.list read (desktop parity): suppress when the idle agent
        // is still waiting on delegated sub-agents, another agent is active, or
        // the idle agent is background per metadata or muted. Fail-open on
        // read failure.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let agents = await fetchWorkspaceAgents(
                workspaceId: context.workspaceId,
                from: sourceBackendID
            )
            guard sourceStillCurrent(sourceBackendID, connectionId: context.connectionId)
            else { return }
            if Self.shouldSuppressIdleAlert(idleAgentId: context.agentId, agentList: agents) {
                AppLog.notifications.debug(
                    "[NotificationManager] Suppressing idle alert — workspace still active or awaited"
                )
                return
            }
            presentIdleAlert(
                agentId: context.agentId,
                workspaceId: context.workspaceId,
                agentName: context.agentName,
                connectionId: context.connectionId,
                sourceBackendID: sourceBackendID
            )
        }
    }

    private func idleEventContext(
        _ params: Any,
        sourceBackendID: BackendID?
    ) -> IdleEventContext? {
        AppLog.notifications.debug(
            "[NotificationManager] handleEvent called, params type=\(type(of: params))"
        )
        guard let event = idleEventDictionary(params)?.event else { return nil }
        guard let data = event["data"] as? [String: Any] else {
            AppLog.notifications.warning(
                "[NotificationManager] ⚠️ agent:idle missing 'data' dict. Event keys: \(event.keys.sorted())"
            )
            return nil
        }
        guard let agentId = data["agentId"] as? String else {
            AppLog.notifications.warning(
                "[NotificationManager] ⚠️ agent:idle data missing 'agentId'. Data keys: \(data.keys.sorted())"
            )
            return nil
        }
        guard let workspaceId = event["workspaceId"] as? String else {
            AppLog.notifications.warning(
                "[NotificationManager] ⚠️ agent:idle missing 'workspaceId'. Event keys: \(event.keys.sorted())"
            )
            return nil
        }
        let connectionId: UUID
        if let sourceBackendID {
            connectionId = sourceBackendID.connectionID
        } else {
            guard let active = activeConnectionId() else { return nil }
            connectionId = active
        }
        AppLog.notifications.debug("[NotificationManager] agent:idle — agentId=\(agentId)")
        if Self.shouldSkipIdleEventFastPath(data) { return nil }
        let agentName = data["agentName"] as? String
            ?? event["actor"].flatMap { ($0 as? [String: Any])?["name"] as? String }
            ?? "Agent"
        return IdleEventContext(
            agentId: agentId,
            workspaceId: workspaceId,
            agentName: agentName,
            connectionId: connectionId
        )
    }

    private func idleEventDictionary(_ params: Any) -> IdleEventDictionary? {
        AppLog.notifications.debug(
            "[NotificationManager] handleEvent called, params type=\(type(of: params))"
        )
        guard let dict = params as? [String: Any] else {
            AppLog.notifications.warning("[NotificationManager] ⚠️ params is not [String: Any], skipping")
            return nil
        }
        AppLog.notifications.debug("[NotificationManager] dict keys: \(dict.keys.sorted())")
        let event: [String: Any]
        if let innerEvent = dict["event"] as? [String: Any] {
            event = innerEvent
            AppLog.notifications.debug(
                "[NotificationManager] Unwrapped inner event, keys: \(event.keys.sorted())"
            )
        } else {
            event = dict
            AppLog.notifications.debug("[NotificationManager] No inner event wrapper, using dict directly")
        }
        let eventType = event["type"] as? String
        AppLog.notifications.debug("[NotificationManager] Event type: \(eventType ?? "nil")")
        return eventType == "agent:idle" ? IdleEventDictionary(event: event) : nil
    }

    /// Whether the event's source is still live: the default session must
    /// still be on the same active connection; a pinned session must still
    /// be observed (not torn down mid-flight).
    func sourceStillCurrent(_ sourceBackendID: BackendID?, connectionId: UUID) -> Bool {
        if let sourceBackendID { return observedSessions[sourceBackendID] != nil }
        return activeConnectionId() == connectionId
    }

    /// The workspace store owning the event source's rows: the pinned
    /// session's store, or the default (injected) store.
    func workspaceStore(for sourceBackendID: BackendID?) -> WorkspaceStore {
        guard let sourceBackendID,
              let observed = observedSessions[sourceBackendID] else { return workspaceStore }
        return observed.session.workspaceStore
    }

    /// Emit-time fast path over the raw `agent:idle` payload: skip background
    /// agents, muted agents (`notificationsMuted: true` is stamped on the
    /// event only when set — PROTOCOL §6.5), and agents the daemon already
    /// marks as waiting on sub-agents.
    nonisolated static func shouldSkipIdleEventFastPath(_ data: [String: Any]) -> Bool {
        if data["isBackground"] as? Bool ?? false { return true }
        if data["notificationsMuted"] as? Bool ?? false { return true }
        if data["isWaitingForOtherAgents"] as? Bool ?? false { return true }
        if let waitingIds = data["waitingForAgentIds"] as? [String], !waitingIds.isEmpty { return true }
        return false
    }

    /// Pure suppress-or-alert decision over a fresh `agent.list` read.
    /// `agents == nil` means the read failed — fail open (alert).
    ///
    /// The waiting-on-children gate is an iOS extension beyond the desktop
    /// port (desktop only honors the emit-time flag). It is safe because the
    /// list read can only under-suppress relative to the emit-time flag (a
    /// consumed watch clears the flag), and over-suppression self-heals: the
    /// awaited child's completion wakes the parent, whose next turn emits a
    /// fresh `agent:idle` with the flag cleared.
    ///
    /// The other-agents gate uses the canonical `AgentSession.isActive`
    /// predicate so status-only active agents suppress premature completion alerts.
    static func shouldSuppressIdleAlert(idleAgentId: String, agents: [AgentSession]) -> Bool {
        shouldSuppressIdleAlert(idleAgentId: idleAgentId, agentList: .sessions(agents))
    }

    static func shouldSuppressIdleAlert(idleAgentId: String, agentList: AgentListFetchResult) -> Bool {
        guard case let .sessions(agents) = agentList else { return false }
        if let idleAgent = agents.first(where: { $0.id == idleAgentId }) {
            if idleAgent.isBackground || idleAgent.notificationsMuted { return true }
            if idleAgent.isWaitingForOtherAgents || !idleAgent.waitingForAgentIds.isEmpty { return true }
        }
        return agents.contains { agent in
            agent.id != idleAgentId && agent.isActive
        }
    }

    /// Fetches the workspace's agents for the suppression decision over the
    /// event source's own connection. Returns nil when the source session is
    /// gone, the read fails, or the response is malformed.
    private func fetchWorkspaceAgents(
        workspaceId: String,
        from sourceBackendID: BackendID?
    ) async -> AgentListFetchResult {
        let sourceConnection: ConnectionManagerRouting
        if let sourceBackendID {
            guard let observed = observedSessions[sourceBackendID] else { return .unavailable }
            sourceConnection = observed.session.connection
        } else {
            sourceConnection = connection
        }
        do {
            let result = try await sourceConnection.request(
                "agent.list",
                params: ["workspaceId": workspaceId]
            )
            if let dict = result as? [String: Any],
               let items = dict["agents"] as? [[String: Any]] {
                return .sessions(items.compactMap { AgentSession.parseAgent($0) })
            }
            return .unavailable
        } catch {
            AppLog.notifications.warning("[NotificationManager] agent.list failed, falling back to alert: \(error)")
            return .unavailable
        }
    }
}
