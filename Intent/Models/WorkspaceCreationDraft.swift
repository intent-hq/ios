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
    /// A pull request's head branch, kept selected even when the first
    /// branch page does not list it.
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
    /// A fresh draft for working on `pullRequest`: its repository and head
    /// branch are selected and the prompt links the pull request, so the
    /// form opens on the final step.
    mutating func prefill(pullRequest: PullRequestListItem) {
        selectedRepo = GitHubRepo(owner: pullRequest.owner, name: pullRequest.repo, htmlUrl: nil, defaultBranch: nil, updatedAt: nil)
        selectedBranch = pullRequest.headRef
        pinnedBranch = pullRequest.headRef
        messageText = pullRequest.url?.absoluteString ?? ""
        navigationPath = pullRequest.headRef == nil ? [.branches] : [.branches, .create]
    }
}
