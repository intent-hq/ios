import Foundation

extension AgentStore {
    /// Refresh the visible list and only the groups the user has requested.
    /// Per-scope request tickets prevent older reads from winning a race;
    /// the epoch also protects a workspace A → B → A navigation sequence.
    func _fetchAgents(workspaceId: String) async {
        guard self.workspaceId == workspaceId, !Task.isCancelled else { return }
        let epoch = list.epoch
        let sequence = list.beginRead()
        list.topLevelRequest = sequence
        if agents.isEmpty { isLoading = true }
        defer {
            if list.epoch == epoch, list.topLevelRequest == sequence, isLoading { isLoading = false }
        }
        do {
            var params: [String: Any] = ["workspaceId": workspaceId]
            if scopedLoading { params["scope"] = "topLevel" }
            let boundary = summaries?.beginRead()
            let result = try await connectionManager.request("agent.list", params: params)
            guard list.epoch == epoch, list.topLevelRequest == sequence else { return }
            try Task.checkCancellation()
            let (response, rows) = try decodeList(result)
            if let boundary { summaries?.seed(rows, workspaceId: workspaceId, since: boundary) }
            list.readMetadata(response, sequence: sequence)
            invalidateLegacyGroupReads(through: sequence)
            replaceRows(rows, group: nil, sequence: sequence)
            if !hasLoaded { hasLoaded = true }
            await refreshRequestedGroups(workspaceId: workspaceId, epoch: epoch, sequence: sequence)
        } catch is CancellationError {
            // A disappearing view must not publish a late response.
        } catch {
            AppLog.agents.error("[AgentStore] Failed to fetch agents: \(error)")
        }
    }

    private func invalidateLegacyGroupReads(through sequence: Int) {
        guard list.scopeCounts == nil else { return }
        for group in list.requestedGroups where group != .retired {
            guard (list.groupRequests[group] ?? 0) <= sequence else { continue }
            list.groupRequests[group] = nil
            list.loadingGroups.remove(group)
            list.loadedGroups.remove(group)
            list.errors[group] = nil
            list.members[group] = nil
        }
    }

    /// Legacy daemons already returned every active row in the initial read.
    func isAgentGroupLoaded(_ group: AgentListGroup) -> Bool {
        if group != .retired, hasLoaded, !scopedLoading || list.scopeCounts == nil { return true }
        return list.loadedGroups.contains(group)
    }

    private func refreshRequestedGroups(workspaceId: String, epoch: UUID, sequence: Int) async {
        // Groups requested during this read own a newer snapshot; leave them
        // alone. Older in-flight reads are superseded by the refresh.
        for group in orderedRequestedGroups {
            guard list.epoch == epoch, list.topLevelRequest == sequence, !Task.isCancelled else { return }
            if (list.groupRequests[group] ?? 0) > sequence { continue }
            await fetchAgentGroup(group, workspaceId: workspaceId, refresh: true)
        }
    }

    /// Expansion is idempotent; failed and cancelled sections can be retried.
    /// Callers use list.loadingGroups, loadedGroups and errors for section UI.
    func loadAgentGroup(_ group: AgentListGroup, workspaceId: String) async {
        guard self.workspaceId == workspaceId, hasLoaded else { return }
        list.requestedGroups.insert(group)
        await fetchAgentGroup(group, workspaceId: workspaceId, refresh: false)
    }

    private func fetchAgentGroup(_ group: AgentListGroup, workspaceId: String, refresh: Bool) async {
        guard !Task.isCancelled else { return }
        if !refresh, list.loadingGroups.contains(group) { return }
        if !refresh, list.loadedGroups.contains(group), list.errors[group] == nil { return }
        // A pre-scope daemon already returned all active rows. Retired rows
        // are still separate and can be fetched on explicit expansion.
        guard group == .retired || (scopedLoading && list.scopeCounts != nil) else { return }
        let epoch = list.epoch
        let sequence = list.beginRead()
        list.groupRequests[group] = sequence
        list.loadingGroups.insert(group)
        list.errors[group] = nil
        let orphanOnly = group == .orphaned && list.delegatedCounts?.orphaned != nil
        defer {
            if list.epoch == epoch, list.groupRequests[group] == sequence { list.loadingGroups.remove(group) }
        }
        do {
            let boundary = summaries?.beginRead()
            let result = try await connectionManager.request(
                "agent.list", params: groupParams(group, workspaceId: workspaceId, orphanOnly: orphanOnly)
            )
            guard list.epoch == epoch, list.groupRequests[group] == sequence else { return }
            try Task.checkCancellation()
            let (response, rows) = try decodeList(result)
            if let boundary { summaries?.seed(rows, workspaceId: workspaceId, since: boundary) }
            list.readMetadata(response, sequence: sequence)
            replaceRows(rows, group: group, sequence: sequence, orphanOnly: orphanOnly)
            list.loadedGroups.insert(group)
        } catch is CancellationError {
            // Keep the section retryable.
        } catch {
            guard list.epoch == epoch, list.groupRequests[group] == sequence else { return }
            list.errors[group] = error.localizedDescription
        }
    }

    private func groupParams(_ group: AgentListGroup, workspaceId: String, orphanOnly: Bool) -> [String: Any] {
        var params: [String: Any] = ["workspaceId": workspaceId]
        switch group {
        case .background: params["scope"] = "background"
        case let .delegated(parentId):
            params["scope"] = "delegated"
            params["parentAgentId"] = parentId
        case .orphaned:
            params["scope"] = "delegated"
            if orphanOnly { params["orphanedOnly"] = true }
        case .retired: params["retiredOnly"] = true
        }
        return params
    }

    private func decodeList(_ result: Any) throws -> ([String: Any], [[String: Any]]) {
        guard let response = result as? [String: Any], let rows = response["agents"] as? [[String: Any]] else {
            throw NSError(domain: "AgentStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid agent list response"])
        }
        return (response, rows)
    }

    /// Stable refresh order also makes retire/restore reconciliation prefer
    /// the retired read, which is the last snapshot taken in a refresh.
    private var orderedRequestedGroups: [AgentListGroup] {
        list.requestedGroups.sorted { groupOrder($0) < groupOrder($1) }
    }

    private func groupOrder(_ group: AgentListGroup) -> String {
        switch group {
        case let .delegated(parentId): return "0-\(parentId)"
        case .orphaned: return "1"
        case .background: return "2"
        case .retired: return "3"
        }
    }

    private func replaceRows(
        _ rows: [[String: Any]], group: AgentListGroup?, sequence: Int, orphanOnly: Bool = false
    ) {
        let parsed = rows.compactMap { AgentSession.parseAgent($0) }
        let incomingIds = Set(parsed.map(\.id))
        let previousMembers = group.flatMap { list.members[$0] } ?? []
        var active = agents
        var retired = list.retiredAgents
        // A scope snapshot can remove its old rows, but cannot erase a row
        // obtained by a newer overlapping read (including retirement moves).
        let removed = (active + retired).filter { row in
            !incomingIds.contains(row.id) && (list.rowSequences[row.id] ?? 0) <= sequence
                && belongsToRead(row, group: group, previousMembers: previousMembers, orphanOnly: orphanOnly)
        }
        let removedIds = Set(removed.map(\.id))
        active.removeAll { removedIds.contains($0.id) }
        retired.removeAll { removedIds.contains($0.id) }
        for id in removedIds { list.rowSequences[id] = sequence }
        for row in parsed where (list.rowSequences[row.id] ?? 0) <= sequence {
            list.rowSequences[row.id] = sequence
            if row.retiredAt == nil {
                retired.removeAll { $0.id == row.id }
                upsert(row, into: &active)
            } else {
                active.removeAll { $0.id == row.id }
                upsert(row, into: &retired)
            }
        }
        if let group {
            list.members[group] = incomingIds
            if group == .orphaned {
                list.orphanedAgentIds = orphanOnly ? incomingIds : []
            }
        }
        if active != agents { agents = active }
        if retired != list.retiredAgents { list.retiredAgents = retired }
        list.orphanedAgentIds.subtract(removedIds)
        list.orphanedAgentIds.subtract(retired.map(\.id))
    }

    private func belongsToRead(
        _ row: AgentSession, group: AgentListGroup?, previousMembers: Set<String>, orphanOnly: Bool
    ) -> Bool {
        if group == .retired { return row.retiredAt != nil }
        guard row.retiredAt == nil else { return false }
        if !scopedLoading || list.scopeCounts == nil { return true }
        switch group {
        case nil: return row.parentAgentId == nil && !row.isBackground
        case .background: return row.parentAgentId == nil && row.isBackground
        case let .delegated(parentId): return row.parentAgentId == parentId
        case .orphaned: return orphanOnly ? previousMembers.contains(row.id) : row.parentAgentId != nil
        case .retired: return false
        }
    }

    private func upsert(_ row: AgentSession, into rows: inout [AgentSession]) {
        if let index = rows.firstIndex(where: { $0.id == row.id }) {
            rows[index] = row
        } else {
            rows.append(row)
        }
    }
}
