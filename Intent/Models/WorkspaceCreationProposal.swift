import Foundation

struct WorkspaceProposalEdits {
    var title: String
    var initialPrompt: String
}

struct WorkspaceCreationProposal {
    private let params: [String: Any]
    private let preview: [String: AnyCodable]

    init?(_ proposal: ActionProposal) {
        guard proposal.kind == "workspace-create",
              proposal.payload["operation"]?.stringValue == "workspace.create",
              let params = proposal.payload["params"]?.value as? [String: Any] else { return nil }
        self.params = params
        preview = proposal.preview.workspaceCreate
    }

    var isSibling: Bool { preview["mode"]?.stringValue == "sibling" }
    var title: String { params["title"] as? String ?? preview["title"]?.stringValue ?? "" }
    var initialPrompt: String {
        if let prompt = initialAgent["prompt"] as? String ?? preview["initialPrompt"]?.stringValue { return prompt }
        return params["initialMessage"] as? String ?? params["initialPrompt"] as? String
            ?? params["prompt"] as? String ?? params["message"] as? String ?? ""
    }
    var repository: String { githubURL ?? repositoryPath ?? "" }
    var branch: String? { params["baseRef"] as? String }
    var specialist: String? { initialAgent["specialist"] as? String ?? preview["specialist"]?.stringValue ?? params["specialist"] as? String }
    var edits: WorkspaceProposalEdits { WorkspaceProposalEdits(title: title, initialPrompt: initialPrompt) }

    private var initialAgent: [String: Any] { params["initialAgent"] as? [String: Any] ?? [:] }
    private var repositoryPath: String? {
        params["repositoryPath"] as? String ?? (isSibling ? nil : preview["repoPath"]?.stringValue)
    }
    private var githubURL: String? {
        params["githubUrl"] as? String ?? (isSibling ? nil : preview["githubUrl"]?.stringValue)
    }

    func request(edits: WorkspaceProposalEdits, fallbackKey: String) throws -> [String: Any] {
        var result = params
        let title = edits.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = edits.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repository.isEmpty else { throw WorkspaceProposalError.missingRepository }
        result["title"] = title.isEmpty ? nil : title
        let clonePath = params["clonePath"] as? String ?? (isSibling ? nil : preview["clonePath"]?.stringValue)
        result["githubUrl"] = githubURL
        result["clonePath"] = clonePath
        result["repositoryPath"] = githubURL?.isEmpty == false && (clonePath ?? "").isEmpty ? nil : repositoryPath
        if result["isNewRepo"] == nil, !isSibling { result["isNewRepo"] = preview["isNewRepo"]?.value }
        if result["scope"] == nil, !isSibling { result["scope"] = preview["scope"]?.stringValue }
        let key = (params["idempotencyKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        result["idempotencyKey"] = key?.isEmpty == false ? params["idempotencyKey"] : fallbackKey
        var agent = initialAgent
        agent.removeValue(forKey: "agentId")
        agent["prompt"] = prompt.isEmpty ? nil : prompt
        agent["specialist"] = specialist
        agent["name"] = agent["name"] as? String ?? "Agent"
        agent["agentType"] = agent["agentType"] as? String ?? "workspace"
        var metadata = agent["metadata"] as? [String: Any] ?? [:]
        metadata["isInitialAgent"] = true
        if let specialist { metadata["specialist"] = specialist }
        agent["metadata"] = metadata
        result["initialAgent"] = agent
        return result
    }
}

enum WorkspaceProposalError: LocalizedError {
    case missingRepository

    var errorDescription: String? { "This proposal is missing its repository. Ask the agent to propose it again." }
}
