import Foundation

struct ScriptMonitorSelection: Identifiable {
    let id: UUID
}

extension ConversationViewModel {
    var scriptMonitorOwnerName: String {
        let name = agentDetails.cached(agentId: agentId)?.values["name"] as? String ?? agentName
        return ScriptMonitorPresentation.ownerName(name, agentId: agentId)
    }

    var activeAgentScriptMonitors: [ScriptMonitorSummary] {
        guard scriptMonitorConsumer != nil, scriptMonitorsStore.isSupported else { return [] }
        return ScriptMonitorPresentation.ownedActive(
            scriptMonitorsStore.rows(for: workspaceId), workspaceId: workspaceId, agentId: agentId
        )
    }

    var showsScriptMonitorStatus: Bool {
        guard scriptMonitorConsumer != nil else { return false }
        return scriptMonitorsStore.isSupported && ScriptMonitorPresentation.showsStatus(
            hasMonitors: !activeAgentScriptMonitors.isEmpty,
            isLoading: scriptMonitorsStore.isLoading(for: workspaceId),
            isStale: scriptMonitorsStore.isStale(for: workspaceId),
            error: scriptMonitorsStore.error(for: workspaceId),
            nextCursor: scriptMonitorsStore.nextCursor(for: workspaceId)
        )
    }

    func activateScriptMonitors() {
        guard scriptMonitorConsumer == nil else { return }
        scriptMonitorConsumer = scriptMonitorsStore.retain(workspaceId: workspaceId)
    }

    func deactivateScriptMonitors() {
        closeScriptMonitor()
        guard let consumer = scriptMonitorConsumer else { return }
        scriptMonitorConsumer = nil
        scriptMonitorsStore.release(workspaceId: workspaceId, consumer: consumer)
    }

    func selectScriptMonitor(_ monitor: ScriptMonitorSummary) {
        guard scriptMonitorConsumer != nil,
              activeAgentScriptMonitors.contains(where: { $0.id == monitor.id && $0.runId == monitor.runId }) else { return }
        closeScriptMonitor()
        selectedScriptMonitor = ScriptMonitorSelection(
            id: scriptMonitorsStore.select(workspaceId: workspaceId, monitorId: monitor.id)
        )
    }

    func closeScriptMonitor() {
        guard let selectedScriptMonitor else { return }
        scriptMonitorsStore.deselect(selection: selectedScriptMonitor.id)
        self.selectedScriptMonitor = nil
    }

    func retryScriptMonitors() async {
        guard scriptMonitorConsumer != nil else { return }
        await scriptMonitorsStore.retry(workspaceId: workspaceId)
    }
}
