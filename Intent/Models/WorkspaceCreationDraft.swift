import Foundation

@MainActor
struct WorkspaceCreationDraft {
    enum Route: Hashable {
        case branches
        case create
        case newRepository
    }

    var navigationPath: [Route] = []
    var selectedRepo: GitHubRepo?
    var selectedBranch: String?
    var newRepositoryDraft = NewRepositoryDraft()
    var newRepositoryPath: String?
    var creationAttempts = WorkspaceCreationAttempts()
    var messageText = ""
    var agentSelection: WorkspaceAgentSelection
    var images = WorkspaceCreationImages()
    var videoSubmission: WorkspaceCreationVideoSubmission?
    var didCreateWorkspace = false
    var pinnedBranch: String?

    init(backendID: BackendID?, persistence: PersistenceManager) {
        agentSelection = WorkspaceAgentSelection(backendID: backendID, persistence: persistence)
    }

    var resumable: Self? {
        guard navigationPath.last == .create,
              !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !images.videos.isEmpty || videoSubmission != nil,
              !didCreateWorkspace else { return nil }
        return self
    }
}

extension WorkspaceCreationDraft {
    mutating func prefill(pullRequest: PullRequestListItem) {
        selectedRepo = GitHubRepo(owner: pullRequest.owner, name: pullRequest.repo, htmlUrl: nil, defaultBranch: nil, updatedAt: nil)
        selectedBranch = pullRequest.headRef
        pinnedBranch = pullRequest.headRef
        messageText = pullRequest.url?.absoluteString ?? ""
        navigationPath = pullRequest.headRef == nil ? [.branches] : [.branches, .create]
    }
}
