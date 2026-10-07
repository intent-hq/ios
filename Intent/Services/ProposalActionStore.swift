import Foundation
import Observation

@MainActor @Observable
final class ProposalActionStore {
    private static let invalidParametersCode = -32_602
    private let connection: SessionConnectionManaging
    private let agentId: String
    private let workspaceId: String
    private let workspaceStore: WorkspaceStore?
    let details: AgentDetailStore
    var pending: [String: String] {
        var result: [String: String] = [:]
        for ref in details.cached(agentId: agentId)?.metadata["pendingProposals"] as? [[String: Any]] ?? [] {
            if let id = ref["proposalId"] as? String, let message = ref["messageId"] as? String { result[id] = message }
        }
        return result
    }
    var resolutions: [String: String] {
        details.cached(agentId: agentId)?.metadata["proposalResolutions"] as? [String: String] ?? [:]
    }
    private(set) var completed: [String: Set<String>] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var isBusy = false
    private(set) var loadError: String?
    private(set) var createdWorkspaces: [String: Workspace] = [:]
    private var creationRequests: [String: [String: Any]] = [:]

    var canCreateWorkspace: Bool {
        connection.connectionState == .connected && connection.currentPrincipal?.canManageWorkspaces == true
    }

    init(
        connection: SessionConnectionManaging,
        agentId: String,
        workspaceId: String,
        details: AgentDetailStore? = nil,
        workspaceStore: WorkspaceStore? = nil
    ) {
        self.connection = connection
        self.agentId = agentId
        self.workspaceId = workspaceId
        self.details = details ?? AgentDetailStore(connection: connection)
        self.workspaceStore = workspaceStore
    }

    func isPending(_ proposal: ActionProposal, messageId: String) -> Bool {
        pending[proposal.id] == messageId
    }

    func receiptKey(_ proposal: ActionProposal, messageId: String) -> String {
        "\(messageId):\(proposal.id)"
    }

    func hasCreationAttempt(_ proposal: ActionProposal, messageId: String) -> Bool {
        creationRequests[receiptKey(proposal, messageId: messageId)] != nil
    }

    func submittedEdits(_ proposal: ActionProposal, messageId: String) -> WorkspaceProposalEdits? {
        guard let request = creationRequests[receiptKey(proposal, messageId: messageId)] else { return nil }
        return WorkspaceProposalEdits(
            title: request["title"] as? String ?? "",
            initialPrompt: (request["initialAgent"] as? [String: Any])?["prompt"] as? String ?? ""
        )
    }

    func createWorkspace(_ proposal: ActionProposal, messageId: String, edits: WorkspaceProposalEdits) async {
        guard !isBusy, canCreateWorkspace, let creation = proposal.workspaceCreation else { return }
        isBusy = true
        defer { isBusy = false }
        errors[proposal.id] = nil
        let key = receiptKey(proposal, messageId: messageId)
        do {
            try await load()
            guard canCreateWorkspace, isPending(proposal, messageId: messageId) else { return }
            if createdWorkspaces[key] == nil {
                let params = try creationRequests[key] ?? creation.request(
                    edits: edits, fallbackKey: "ios-proposal:\(workspaceId):\(agentId):\(key)"
                )
                creationRequests[key] = params
                let workspace = try await requestWorkspace(params, receiptKey: key)
                createdWorkspaces[key] = workspace
                workspaceStore?.addOrUpdate(workspace)
            }
            try await resolve(proposal, outcome: "applied", detail: createdWorkspaces[key].map { "Created workspace \($0.id)." })
        } catch {
            errors[proposal.id] = createdWorkspaces[key] == nil ? error.localizedDescription
                : "Workspace created, but the confirmation could not be saved. Retry to confirm. \(error.localizedDescription)"
        }
    }

    private func requestWorkspace(_ params: [String: Any], receiptKey: String) async throws -> Workspace {
        let response: Any
        do {
            response = try await connection.request("workspace.create", params: params, timeout: CreateWorkspaceView.createRequestTimeout)
        } catch {
            let failure = error as NSError
            if failure.domain == "WebSocket", failure.code == Self.invalidParametersCode {
                creationRequests[receiptKey] = nil
            }
            throw error
        }
        guard let result = response as? [String: Any], let row = result["workspace"] as? [String: Any],
              let workspace = WorkspaceStore.parseWorkspace(row), !workspace.id.isEmpty else {
            throw ProposalError.invalidResponse
        }
        return workspace
    }

    func refresh() async {
        guard !isBusy else { return }
        do { try await load() } catch { loadError = error.localizedDescription }
    }

    func loadIfPresent(in messages: [ConversationMessage]) async {
        guard messages.contains(where: { $0.contentBlocks.contains { ActionProposal.parse($0) != nil } }) else { return }
        await loadIfNeeded()
    }

    /// Card appearance and metadata-generation view tasks reuse settled detail.
    func loadIfNeeded() async {
        guard !isBusy else { return }
        do { try await load(refresh: false) } catch { loadError = error.localizedDescription }
    }

    private func load(refresh: Bool = true) async throws {
        _ = try await details.load(agentId: agentId, workspaceId: workspaceId, refresh: refresh)
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
        guard !isBusy, !hasCreationAttempt(proposal, messageId: messageId) else { return }
        isBusy = true
        defer { isBusy = false }
        errors[proposal.id] = nil
        do {
            try await load()
            guard isPending(proposal, messageId: messageId) else { return }
            try await resolve(proposal, outcome: "dismissed")
        } catch { errors[proposal.id] = error.localizedDescription }
    }

    private func resolve(_ proposal: ActionProposal, outcome: String, detail: String? = nil) async throws {
        var params: [String: Any] = [
            "agentId": agentId, "workspaceId": workspaceId, "proposalId": proposal.id, "outcome": outcome
        ]
        if let detail { params["detail"] = detail }
        let response = try await connection.request("agent.resolveProposal", params: params)
        guard let result = response as? [String: Any], result["success"] as? Bool == true,
              let recorded = result["outcome"] as? String else { throw ProposalError.invalidResponse }
        var resolutions = resolutions
        resolutions[proposal.id] = recorded
        let pending = pending.filter { $0.key != proposal.id }.map { ["proposalId": $0.key, "messageId": $0.value] }
        details.updateMetadata(agentId: agentId, fields: ["pendingProposals": pending, "proposalResolutions": resolutions])
    }
}

private enum ProposalError: LocalizedError {
    case invalidResponse

    var errorDescription: String? { "The server returned an incomplete response. Please retry." }
}
