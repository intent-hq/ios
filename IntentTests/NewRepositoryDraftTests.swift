import Foundation
@testable import Intent
import Testing

struct NewRepositoryDraftTests {
    @Test(arguments: ["", "  ", ".", "..", "...", "../project", "a/b", "a\\b", "a\0b", "a\nb", "a:b", "a?b"])
    func invalidNamesCannotProduceAPath(name: String) {
        let draft = NewRepositoryDraft(name: name)
        #expect(draft.validationError != nil)
        #expect(draft.repositoryPath == nil)
    }

    @Test(arguments: ["", "Developer", "~someone/Developer", "/tmp/../projects", "~/./projects", "/tmp\n/projects", "/tmp\\projects"])
    func invalidParentsCannotProduceAPath(parent: String) {
        let draft = NewRepositoryDraft(name: "project", parentPath: parent)
        #expect(draft.validationError != nil)
        #expect(draft.repositoryPath == nil)
    }

    @Test func trimsInputsAndKeepsTildeForTheHostToExpand() {
        let draft = NewRepositoryDraft(name: "  My Project  ", parentPath: "  ~/Developer///  ")
        #expect(draft.validationError == nil)
        #expect(draft.repositoryPath == "~/Developer/My Project")
    }

    @Test func supportsAbsoluteAndHomeFolders() {
        #expect(NewRepositoryDraft(name: "project", parentPath: "/").repositoryPath == "/project")
        #expect(NewRepositoryDraft(name: "project", parentPath: "/tmp//projects/").repositoryPath == "/tmp/projects/project")
        #expect(NewRepositoryDraft(name: "project", parentPath: "~").repositoryPath == "~/project")
    }

    @Test func measuresFilenameLimitInBytes() {
        let valid = String(repeating: "a", count: 255)
        #expect(NewRepositoryDraft(name: valid).repositoryPath != nil)
        #expect(NewRepositoryDraft(name: valid + "a").repositoryPath == nil)
        #expect(NewRepositoryDraft(name: String(repeating: "é", count: 128)).repositoryPath == nil)
    }

    @Test func existingFilesAndFoldersAreRejected() {
        #expect(NewRepositoryDraft.destinationError(for: ["exists": true, "isDirectory": true]) != nil)
        #expect(NewRepositoryDraft.destinationError(for: ["exists": true, "isDirectory": false]) != nil)
        #expect(NewRepositoryDraft.destinationError(for: ["exists": false]) == nil)
    }

    @Test func malformedDirectoryResponseCannotAuthorizeCreation() {
        #expect(NewRepositoryDraft.destinationError(for: [:]) != nil)
        #expect(NewRepositoryDraft.destinationError(for: ["exists": "false"]) != nil)
        #expect(NewRepositoryDraft.destinationError(for: NSNull()) != nil)
    }

    @Test func newRepositoryRequestOmitsGitHubAndBranchAndKeepsAgentSettings() throws {
        let agent = CreateWorkspaceView.InitialAgentInput(
            specialist: nil,
            provider: ProviderInfo(id: "codex", authenticated: .signedIn),
            model: ModelInfo(id: "chosen-model", name: "Chosen Model", provider: "codex"),
            message: "  Build this project  ",
            reasoningEffort: "high",
            imageBlocks: [["type": "image", "data": "fixture"]]
        )
        let params = CreateWorkspaceView.buildCreateWorkspaceParams(
            source: .newRepository(path: "~/Developer/my-project"),
            idempotencyKey: "retry-key",
            initialAgent: agent
        )
        #expect(params["repositoryPath"] as? String == "~/Developer/my-project")
        #expect(params["isNewRepo"] as? Bool == true)
        #expect(params["githubUrl"] == nil)
        #expect(params["baseRef"] == nil)
        #expect(params["branch"] == nil)
        #expect(params["idempotencyKey"] as? String == "retry-key")
        let initialAgent = try #require(params["initialAgent"] as? [String: Any])
        #expect(initialAgent["prompt"] as? String == "Build this project")
        #expect(initialAgent["provider"] as? String == "codex")
        #expect(initialAgent["model"] as? String == "chosen-model")
        #expect(initialAgent["reasoningEffort"] as? String == "high")
        #expect((initialAgent["imageBlocks"] as? [[String: String]])?.first?["data"] == "fixture")
    }

    @Test func existingRepositoryRequestOmitsNewRepositoryFields() {
        let params = CreateWorkspaceView.buildCreateWorkspaceParams(
            source: .github(url: "https://github.com/owner/repo", baseRef: "feature/docs"),
            idempotencyKey: "existing-key",
            initialAgent: .init(specialist: nil, provider: nil, model: nil, message: "")
        )
        #expect(params["githubUrl"] as? String == "https://github.com/owner/repo")
        #expect(params["baseRef"] as? String == "feature/docs")
        #expect(params["repositoryPath"] == nil)
        #expect(params["isNewRepo"] == nil)
        #expect(params["initialAgent"] == nil)
    }
}
