import Foundation
import Observation

@MainActor @Observable
final class ProposalActionStore {
    private let connection: ConnectionManagerRouting
    private let agentId: String
    private let workspaceId: String
    private(set) var pending: [String: String] = [:]
    private(set) var resolutions: [String: String] = [:]
    private(set) var completed: [String: Set<String>] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var isBusy = false
    private(set) var loadError: String?
    private var generation = 0

    init(connection: ConnectionManagerRouting, agentId: String, workspaceId: String) {
        self.connection = connection
        self.agentId = agentId
        self.workspaceId = workspaceId
    }

    func isPending(_ proposal: ActionProposal, messageId: String) -> Bool {
        pending[proposal.id] == messageId
    }

    func receiptKey(_ proposal: ActionProposal, messageId: String) -> String {
        "\(messageId):\(proposal.id)"
    }

    func refresh() async {
        guard !isBusy else { return }
        do { try await load() } catch { loadError = error.localizedDescription }
    }

    private func load() async throws {
        generation += 1
        let requestedGeneration = generation
        let response = try await connection.request("agent.get", params: ["agentId": agentId, "workspaceId": workspaceId])
        guard requestedGeneration == generation else { return }
        guard let response = response as? [String: Any], let agent = response["agent"] as? [String: Any] else {
            throw ProposalError.invalidResponse
        }
        let metadata = agent["metadata"] as? [String: Any] ?? [:]
        var next: [String: String] = [:]
        for ref in metadata["pendingProposals"] as? [[String: Any]] ?? [] {
            if let id = ref["proposalId"] as? String, let message = ref["messageId"] as? String { next[id] = message }
        }
        pending = next
        resolutions = metadata["proposalResolutions"] as? [String: String] ?? [:]
        loadError = nil
    }

    func apply(_ proposal: ActionProposal, messageId: String, selection: Set<String>) async {
        guard !isBusy, let method = proposal.method else { return }
        let selected = selection.intersection(proposal.selectableIDs)
        guard !selected.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        errors[proposal.id] = nil
        do {
            try await load()
            guard isPending(proposal, messageId: messageId) else { return }
            let key = receiptKey(proposal, messageId: messageId)
            for id in proposal.workspaceIDs where selected.contains(id) && !(completed[key] ?? []).contains(id) {
                let response = try await connection.request(method, params: ["workspaceId": id])
                guard let result = response as? [String: Any],
                      result["success"] as? Bool == true || result["workspace"] is [String: Any] else {
                    throw ProposalError.invalidResponse
                }
                completed[key, default: []].insert(id)
            }
            try await resolve(proposal, outcome: "applied")
        } catch { errors[proposal.id] = error.localizedDescription }
    }

    func dismiss(_ proposal: ActionProposal, messageId: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await load()
            guard isPending(proposal, messageId: messageId) else { return }
            try await resolve(proposal, outcome: "dismissed")
        } catch { errors[proposal.id] = error.localizedDescription }
    }

    private func resolve(_ proposal: ActionProposal, outcome: String) async throws {
        let response = try await connection.request("agent.resolveProposal", params: [
            "agentId": agentId, "workspaceId": workspaceId, "proposalId": proposal.id, "outcome": outcome
        ])
        guard let result = response as? [String: Any], result["success"] as? Bool == true,
              let recorded = result["outcome"] as? String else { throw ProposalError.invalidResponse }
        generation += 1
        resolutions[proposal.id] = recorded
        pending[proposal.id] = nil
    }
}

private enum ProposalError: LocalizedError {
    case invalidResponse

    var errorDescription: String? { "The server returned an incomplete response. Please retry." }
}
