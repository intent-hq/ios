import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceCreationDraftTests {
    @Test(arguments: ["", " ", "\n\t "])
    func blankPromptDoesNotResume(message: String) {
        var draft = makeDraft()
        draft.navigationPath = [.branches, .create]
        draft.messageText = message
        #expect(draft.resumable == nil)
    }

    @Test(arguments: [[], [.branches], [.newRepository]] as [[WorkspaceCreationDraft.Route]])
    func earlierScreensDoNotResume(path: [WorkspaceCreationDraft.Route]) {
        var draft = makeDraft()
        draft.navigationPath = path
        draft.messageText = "Started a prompt before going back"
        #expect(draft.resumable == nil)
    }

    @Test func restoresPromptSourceAndAgentChoices() throws {
        var draft = makeDraft()
        draft.navigationPath = [.branches, .create]
        draft.selectedRepo = GitHubRepo(owner: "owner", name: "project", htmlUrl: nil, defaultBranch: "main", updatedAt: nil)
        draft.selectedBranch = "feature/draft"
        draft.messageText = "  Keep my formatting\nAnd this line  "
        let specialist = SpecialistInfo(id: "verifier", name: "Verifier", description: "Reviews")
        let provider = ProviderInfo(id: "codex", authenticated: .signedIn)
        let model = ModelInfo(id: "chosen", name: "Chosen", provider: "codex", effortLevels: ["high"])
        draft.agentSelection.selectSpecialist(specialist)
        draft.agentSelection.selectProvider(provider)
        draft.agentSelection.selectModel(model)
        draft.agentSelection.selectReasoning("high")

        let restored = try #require(draft.resumable)
        #expect(restored.navigationPath == [.branches, .create])
        #expect(restored.selectedRepo == draft.selectedRepo)
        #expect(restored.selectedBranch == "feature/draft")
        #expect(restored.messageText == "  Keep my formatting\nAnd this line  ")
        #expect(restored.agentSelection.specialist == specialist)
        #expect(restored.agentSelection.provider == provider)
        #expect(restored.agentSelection.model == model)
        #expect(restored.agentSelection.reasoningEffort == "high")
        #expect(restored.images === draft.images)
    }

    @Test func newRepositoryAndFailedAttemptKeepTheirRetryKey() throws {
        var draft = makeDraft()
        draft.navigationPath = [.newRepository, .create]
        draft.newRepositoryDraft = NewRepositoryDraft(name: "project", parentPath: "~/Projects")
        draft.newRepositoryPath = draft.newRepositoryDraft.repositoryPath
        draft.messageText = "Build a new project"
        let source = WorkspaceRepositorySource.newRepository(path: "~/Projects/project")
        let key = draft.creationAttempts.requestKey(for: source)
        draft.creationAttempts.record(key, for: source)

        let restored = try #require(draft.resumable)
        #expect(restored.navigationPath == [.newRepository, .create])
        #expect(restored.newRepositoryDraft == draft.newRepositoryDraft)
        #expect(restored.newRepositoryPath == "~/Projects/project")
        #expect(restored.creationAttempts.requestKey(for: source) == key)
    }

    @Test func deletingPromptOrCreatingWorkspaceClearsSavedDraft() throws {
        var draft = makeDraft()
        draft.navigationPath = [.branches, .create]
        draft.messageText = "Build it"
        var saved = try #require(draft.resumable)
        saved.messageText = ""
        #expect(saved.resumable == nil)

        saved = try #require(draft.resumable)
        saved.didCreateWorkspace = true
        #expect(saved.resumable == nil)
    }

    @Test func windowsOnTheSameBackendKeepDraftsAndMutableStateIndependent() throws {
        let backendID = BackendID(UUID())
        let persistence = PersistenceManager.ephemeral()
        let connection = FakeConnectionManager()
        let workspaces = WorkspaceStore(connectionManager: connection)
        let first = AppCoordinator(workspaceStore: workspaces, connection: connection, backendID: backendID, persistence: persistence)
        let second = AppCoordinator(workspaceStore: workspaces, connection: connection, backendID: backendID, persistence: persistence)
        var draft = first.makeWorkspaceCreationDraft()
        draft.navigationPath = [.branches, .create]
        draft.messageText = "First window's prompt"
        let codex = ProviderInfo(id: "codex", authenticated: .signedIn)
        draft.agentSelection.selectProvider(codex)
        first.workspaceCreationDraft = try #require(draft.resumable)

        let reopened = first.makeWorkspaceCreationDraft()
        var sibling = second.makeWorkspaceCreationDraft()
        #expect(reopened.messageText == draft.messageText)
        #expect(sibling.messageText.isEmpty)
        #expect(sibling.navigationPath.isEmpty)
        #expect(sibling.agentSelection !== reopened.agentSelection)
        #expect(sibling.images !== reopened.images)
        sibling.agentSelection.selectProvider(ProviderInfo(id: "auggie", authenticated: .signedIn))
        #expect(reopened.agentSelection.provider == codex)

        let importing = try #require(reopened.images.add([{ Data() }]))
        defer { reopened.images.cancelImport() }
        sibling.images.cancelImport()
        #expect(reopened.images.isImporting)
        #expect(!importing.isCancelled)

        sibling.navigationPath = [.newRepository, .create]
        sibling.messageText = "Second window's prompt"
        second.workspaceCreationDraft = try #require(sibling.resumable)
        #expect(first.makeWorkspaceCreationDraft().messageText == draft.messageText)
        first.workspaceCreationDraft = nil
        #expect(first.makeWorkspaceCreationDraft().messageText.isEmpty)
        #expect(second.makeWorkspaceCreationDraft().messageText == sibling.messageText)
    }

    private func makeDraft() -> WorkspaceCreationDraft {
        WorkspaceCreationDraft(backendID: BackendID(UUID()), persistence: .ephemeral())
    }
}
