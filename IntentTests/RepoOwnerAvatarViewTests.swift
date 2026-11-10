import Foundation
@testable import Intent
import Testing

struct RepoOwnerAvatarViewTests {
    @Test func avatarURLForOwner() {
        let url = RepoOwnerAvatarView.avatarURL(for: "octocat")
        #expect(url?.absoluteString == "https://github.com/octocat.png?size=64")
    }

    @Test func avatarURLForNilOwner() {
        #expect(RepoOwnerAvatarView.avatarURL(for: nil) == nil)
    }

    @Test func avatarURLForEmptyOwner() {
        #expect(RepoOwnerAvatarView.avatarURL(for: "") == nil)
    }

    @MainActor
    @Test func backendScopedDraftsIsolateSameAgentAcrossBackends() throws {
        let suiteName = "BackendScopedDrafts-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = PersistenceManager(defaults: defaults, keychainStorage: EphemeralKeychainStorage())
        let backendA = BackendID(UUID())
        let backendB = BackendID(UUID())

        persistence.saveDraft("Draft on Mac A", workspaceId: Workspace.chiefWorkspaceId, agentId: "assistant-1", backendID: backendA)
        persistence.saveDraft("Draft on Mac B", workspaceId: Workspace.chiefWorkspaceId, agentId: "assistant-1", backendID: backendB)

        let connection = FakeConnectionManager()
        let vmA = ConversationViewModel(
            agentId: "assistant-1",
            workspaceId: Workspace.chiefWorkspaceId,
            agentName: "Assistant",
            connection: connection,
            uploadService: AttachmentUploadService(connection: connection),
            optionsStore: CreationOptionsStore(connectionManager: connection),
            backendID: backendA,
            persistence: persistence
        )
        let vmB = ConversationViewModel(
            agentId: "assistant-1",
            workspaceId: Workspace.chiefWorkspaceId,
            agentName: "Assistant",
            connection: connection,
            uploadService: AttachmentUploadService(connection: connection),
            optionsStore: CreationOptionsStore(connectionManager: connection),
            backendID: backendB,
            persistence: persistence
        )

        #expect(vmA.messageText == "Draft on Mac A")
        #expect(vmB.messageText == "Draft on Mac B")

        persistence.clearDraft(workspaceId: Workspace.chiefWorkspaceId, agentId: "assistant-1", backendID: backendA)
        #expect(persistence.loadDraft(workspaceId: Workspace.chiefWorkspaceId, agentId: "assistant-1", backendID: backendA).isEmpty)
        #expect(persistence.loadDraft(workspaceId: Workspace.chiefWorkspaceId, agentId: "assistant-1", backendID: backendB) == "Draft on Mac B")
    }
}
