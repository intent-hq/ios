import Foundation
import Observation

extension WorkspaceScriptMonitorsStore {
    enum DetailState: Equatable {
        case loading
        case loaded(ScriptMonitorDetail)
        case unavailable
        case failed(String)
    }

    @Observable final class Selection {
        let workspaceId: String
        let monitorId: String
        let runId: String?
        var summary: ScriptMonitorSummary?
        var state: DetailState = .loading
        var terminal = false
        @ObservationIgnored var generation = 0
        @ObservationIgnored var attempted = false
        @ObservationIgnored var task: Task<Void, Never>?
        @ObservationIgnored var completion: WorkspaceStatusWaiters<Void>?

        init(workspaceId: String, monitorId: String, summary: ScriptMonitorSummary?) {
            self.workspaceId = workspaceId
            self.monitorId = monitorId
            self.summary = summary
            self.runId = summary?.runId
        }

        func invalidate(state: DetailState) {
            generation &+= 1
            task?.cancel()
            task = nil
            completion?.finish(())
            completion = nil
            attempted = false
            self.state = state
        }
    }

    func select(workspaceId: String, monitorId: String) -> UUID {
        let id = UUID()
        let summary = rows(for: workspaceId).first { $0.monitorId == monitorId }
        let selection = Selection(workspaceId: workspaceId, monitorId: monitorId, summary: summary)
        if summary == nil || !isSupported { selection.state = .unavailable }
        selections[id] = selection
        return id
    }

    func detailSummary(selection id: UUID) -> ScriptMonitorSummary? {
        isSupported ? selections[id]?.summary : nil
    }

    func detailState(selection id: UUID) -> DetailState { isSupported ? selections[id]?.state ?? .unavailable : .unavailable }

    func deselect(selection id: UUID) {
        selections.removeValue(forKey: id)?.invalidate(state: .unavailable)
    }

    func loadDetail(selection id: UUID, retry: Bool = false) async {
        guard isSupported, let selection = selections[id], selection.runId != nil,
              selection.state != .unavailable, !Task.isCancelled else { return }
        if let completion = selection.completion { await completion.wait(cancelledValue: ()); return }
        guard retry || !selection.attempted else { return }
        selection.attempted = true
        selection.state = .loading
        let generation = selection.generation
        let completion = WorkspaceStatusWaiters<Void>()
        selection.completion = completion
        selection.task = Task { [weak self] in
            defer { completion.finish(()) }
            guard let self else { return }
            await readDetail(selection, id: id, generation: generation, retry: retry)
            guard ownsSelection(selection, id: id, generation: generation) else { return }
            selection.task = nil
            selection.completion = nil
        }
        await completion.wait(cancelledValue: ())
    }

    private func readDetail(_ selection: Selection, id: UUID, generation: Int, retry: Bool) async {
        do {
            // A selected sheet shares the acknowledged feed; reconnect seeds page one
            // before revalidating an off-page selection, without treating absence as terminal.
            let repairFeed = retry && (cache.feeds[selection.workspaceId]?.id == nil
                || cache.buckets[selection.workspaceId]?.accessBlocked == true)
            await cache.load(workspaceId: selection.workspaceId, refresh: repairFeed)
            guard ownsSelection(selection, id: id, generation: generation), isSupported else { return }
            guard cache.feeds[selection.workspaceId]?.id != nil, cache.buckets[selection.workspaceId]?.accessBlocked != true else {
                selection.state = .failed("Script watch details are unavailable. Retry to reconnect.")
                return
            }
            let result = try await connection.request("scriptMonitor.get", params: [
                "workspaceId": selection.workspaceId, "monitorId": selection.monitorId
            ])
            guard ownsSelection(selection, id: id, generation: generation), isSupported else { return }
            let detail = try ScriptMonitorDetail(result, workspaceId: selection.workspaceId, monitorId: selection.monitorId)
            guard detail.summary.runId == selection.runId else { throw ScriptMonitorReadError.invalidResponse }
            selection.summary = detail.summary
            selection.state = .loaded(detail)
        } catch {
            guard ownsSelection(selection, id: id, generation: generation), isSupported else { return }
            let rpc = error as NSError
            if rpc.domain == "WebSocket", rpc.code == Self.invalidParameters {
                selection.terminal = true
                selection.summary = nil
                selection.state = .unavailable
                if let bucket = cache.buckets[selection.workspaceId] {
                    cache.recoverPage(bucket, workspaceId: selection.workspaceId)
                }
            } else {
                selection.state = .failed(error.localizedDescription)
                readFailed(error, workspaceId: selection.workspaceId)
            }
        }
    }

    private func ownsSelection(_ selection: Selection, id: UUID, generation: Int) -> Bool {
        selections[id] === selection && selection.generation == generation
    }

    func invalidateDetails() {
        for selection in selections.values {
            selection.summary = nil
            selection.invalidate(state: selection.terminal ? .unavailable : .loading)
        }
    }

    func revalidateDetails(workspaceId: String) {
        // Only open sheets re-read details. A replacement page may omit an active
        // selection through pagination, so absence cannot establish its outcome.
        for (id, selection) in selections where selection.workspaceId == workspaceId
            && selection.runId != nil && !selection.terminal {
            selection.summary = rows(for: workspaceId).first { $0.monitorId == selection.monitorId }
            selection.invalidate(state: .loading)
            Task { [weak self] in await self?.loadDetail(selection: id) }
        }
    }

    func receiveDetailEvent(_ type: String, data: [String: Any], workspaceId: String) {
        for selection in selections.values where selection.workspaceId == workspaceId
            && selection.monitorId == data["monitorId"] as? String
            && selection.runId == data["runId"] as? String {
            if Self.terminalEvents.contains(type) {
                selection.terminal = true
                selection.summary = nil
                selection.invalidate(state: .unavailable)
            } else if let summary = data["summary"] as? ScriptMonitorSummary, summary != selection.summary {
                selection.summary = summary
                selection.invalidate(state: .failed("This watch changed. Retry to update its details."))
            }
        }
    }
}
