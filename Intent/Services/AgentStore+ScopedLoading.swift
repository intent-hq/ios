import Foundation

extension AgentStore {
    func _fetchAgents(workspaceId: String) async {
        guard self.workspaceId == workspaceId, !Task.isCancelled else { return }
        let epoch = list.epoch
        let sequence = list.beginRead()
        list.topLevelRequest = sequence
        if !hasLoaded { setLoadPhase(loadPhase.beginning()) }
        defer {
            if list.epoch == epoch, list.topLevelRequest == sequence { setLoadPhase(loadPhase.settled()) }
        }
        do {
            var params: [String: Any] = ["workspaceId": workspaceId]
            if scopedLoading { params["scope"] = "topLevel" }
            let boundary = summaries?.beginRead()
            let result = try await PagedReads.requestAgentList(params, connection: connectionManager) {
                list.epoch == epoch && list.topLevelRequest == sequence
            }
            guard list.epoch == epoch, list.topLevelRequest == sequence else { return }
            try Task.checkCancellation()
            let (response, rows) = try decodeList(result)
            if let boundary { summaries?.seed(rows, workspaceId: workspaceId, since: boundary) }
            list.readMetadata(response, sequence: sequence)
            invalidateLegacyGroupReads(through: sequence)
            replaceRows(rows, group: nil, sequence: sequence)
            if !hasLoaded { setLoadPhase(.loaded(Date())) }
            await refreshRequestedGroups(workspaceId: workspaceId, epoch: epoch, sequence: sequence)
        } catch is CancellationError {
        } catch {
            AppLog.agents.error("[AgentStore] Failed to fetch agents: \(error)")
            if list.epoch == epoch, list.topLevelRequest == sequence { setLoadPhase(loadPhase.failing(error)) }
        }
    }

    private func setLoadPhase(_ next: LoadPhase) {
        if next != loadPhase { loadPhase = next }
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

    func isAgentGroupLoaded(_ group: AgentListGroup) -> Bool {
        if group != .retired, hasLoaded, !scopedLoading || list.scopeCounts == nil { return true }
        return list.loadedGroups.contains(group)
    }

    private func refreshRequestedGroups(workspaceId: String, epoch: UUID, sequence: Int) async {
        for group in orderedRequestedGroups {
            guard list.epoch == epoch, list.topLevelRequest == sequence, !Task.isCancelled else { return }
            if (list.groupRequests[group] ?? 0) > sequence { continue }
            await fetchAgentGroup(group, workspaceId: workspaceId, refresh: true)
        }
    }

    func loadAgentGroup(_ group: AgentListGroup, workspaceId: String) async {
        guard self.workspaceId == workspaceId, hasLoaded else { return }
        list.requestedGroups.insert(group)
        await fetchAgentGroup(group, workspaceId: workspaceId, refresh: false)
    }

    private func fetchAgentGroup(_ group: AgentListGroup, workspaceId: String, refresh: Bool) async {
        guard !Task.isCancelled else { return }
        if !refresh, list.loadingGroups.contains(group) { return }
        if !refresh, list.loadedGroups.contains(group), list.errors[group] == nil { return }
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
            let result = try await PagedReads.requestAgentList(
                groupParams(group, workspaceId: workspaceId, orphanOnly: orphanOnly), connection: connectionManager
            ) { list.epoch == epoch && list.groupRequests[group] == sequence }
            guard list.epoch == epoch, list.groupRequests[group] == sequence else { return }
            try Task.checkCancellation()
            let (response, rows) = try decodeList(result)
            if let boundary { summaries?.seed(rows, workspaceId: workspaceId, since: boundary) }
            list.readMetadata(response, sequence: sequence)
            replaceRows(rows, group: group, sequence: sequence, orphanOnly: orphanOnly)
            list.loadedGroups.insert(group)
        } catch is CancellationError {
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
        let scope = readScope(group: group, orphanOnly: orphanOnly)
        let parsed = rows.compactMap { AgentSession.parseAgent($0) }.filter { row in
            !list.coverage.contains { $0.value > sequence && $0.key.contains(row) }
        }
        list.coverage[scope] = max(list.coverage[scope] ?? 0, sequence)
        let incomingIds = Set(parsed.map(\.id))
        let previousMembers = group.flatMap { list.members[$0] } ?? []
        if let group {
            list.members[group] = Set(incomingIds.filter { (list.rowSequences[$0] ?? 0) <= sequence })
        }
        var active = agents
        var retired = list.retiredAgents
        invalidateCoveredMemberships(scope, incomingIds: incomingIds, sequence: sequence)
        let removed = (active + retired).filter { row in
            !incomingIds.contains(row.id) && !retainedByAnotherGroup(row, excluding: group)
                && (list.rowSequences[row.id] ?? 0) <= sequence
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
        if group == .orphaned {
            list.orphanedAgentIds = orphanOnly ? list.members[.orphaned] ?? [] : []
        }
        if active != agents { agents = active }
        if retired != list.retiredAgents { list.retiredAgents = retired }
        list.orphanedAgentIds.subtract(removedIds)
        list.orphanedAgentIds.subtract(retired.map(\.id))
    }

    private func readScope(group: AgentListGroup?, orphanOnly: Bool) -> AgentListReadScope {
        if group == .retired { return .retired }
        if !scopedLoading || list.scopeCounts == nil { return .allActive }
        switch group {
        case nil: return .topLevel
        case .background: return .background
        case let .delegated(parentId): return .delegated(parentId: parentId)
        case .orphaned: return orphanOnly ? .orphaned : .delegated(parentId: nil)
        case .retired: return .retired
        }
    }

    private func invalidateCoveredMemberships(_ scope: AgentListReadScope, incomingIds: Set<String>, sequence: Int) {
        let absent = (agents + list.retiredAgents).filter { row in
            !incomingIds.contains(row.id) && (list.rowSequences[row.id] ?? 0) <= sequence && scope.contains(row)
        }
        let absentIds = Set(absent.map(\.id))
        for group in Array(list.members.keys) { list.members[group]?.subtract(absentIds) }
    }

    private func retainedByAnotherGroup(_ row: AgentSession, excluding group: AgentListGroup?) -> Bool {
        list.members.contains { other, ids in
            guard other != group, ids.contains(row.id) else { return false }
            if other == .retired { return row.retiredAt != nil }
            guard row.retiredAt == nil else { return false }
            switch other {
            case .background: return row.parentAgentId == nil && row.isBackground
            case let .delegated(parentId): return row.parentAgentId == parentId
            case .orphaned: return row.parentAgentId != nil
            case .retired: return false
            }
        }
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
