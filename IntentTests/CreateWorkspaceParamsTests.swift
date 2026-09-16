@testable import Intent
import SwiftUI
import Testing

struct CreateWorkspaceParamsTests {
    func makeSpecialist(
        id: String = "implementor",
        resolvedModel: String? = nil,
        resolvedProvider: String? = nil
    ) -> SpecialistInfo {
        SpecialistInfo(
            id: id,
            name: "Implementor",
            description: "Implements tasks",
            resolvedModel: resolvedModel,
            resolvedProvider: resolvedProvider
        )
    }

    func makeModel(id: String = "sonnet4.5", provider: String = "auggie") -> ModelInfo {
        ModelInfo(id: id, name: "\(id) (balanced)", provider: provider)
    }

    func makeProvider(
        id: String = "auggie",
        authenticated: ProviderAuthentication = .signedIn
    ) -> ProviderInfo {
        ProviderInfo(id: id, authenticated: authenticated)
    }

    func buildParams(
        baseRef: String = "main",
        specialist: SpecialistInfo? = nil,
        provider: ProviderInfo? = nil,
        model: ModelInfo? = nil,
        message: String = ""
    ) -> [String: Any] {
        CreateWorkspaceView.buildCreateWorkspaceParams(
            githubUrl: "https://github.com/intent-hq/intentd",
            baseRef: baseRef,
            idempotencyKey: "key-123",
            specialist: specialist,
            provider: provider,
            model: model,
            message: message
        )
    }

    // MARK: - agentId regression (agent IDs are server-assigned)

    @Test func initialAgentOmitsAgentId() throws {
        let params = buildParams(specialist: makeSpecialist(), model: makeModel(), message: "Do the thing")
        let initialAgent = try #require(params["initialAgent"] as? [String: Any])
        #expect(initialAgent["agentId"] == nil)
    }

    @Test func initialAgentOmitsAgentIdWithMessageOnly() throws {
        let params = buildParams(message: "Just a prompt")
        let initialAgent = try #require(params["initialAgent"] as? [String: Any])
        #expect(initialAgent["agentId"] == nil)
        #expect(initialAgent["prompt"] as? String == "Just a prompt")
    }

    // MARK: - Base params (githubUrl-based cache-hydrated creation)

    @Test func baseParamsAlwaysPresent() {
        let params = buildParams()
        #expect(params["githubUrl"] as? String == "https://github.com/intent-hq/intentd")
        #expect(params["baseRef"] as? String == "main")
        #expect(params["idempotencyKey"] as? String == "key-123")
    }

    @Test func localPathParamsOmitted() {
        // Omitting repositoryPath/clonePath alongside githubUrl selects the
        // daemon's cache-hydrated clone path (PROTOCOL §5.1).
        let params = buildParams()
        #expect(params["repositoryPath"] == nil)
        #expect(params["clonePath"] == nil)
    }

    @Test func createRequestTimeoutMatchesCloudlandsFe() {
        // 120s mirrors cloudlands-fe's CREATE_TIMEOUT_MS (#1954): the daemon's
        // ~70s NPX budget plus first-turn overhead exceeds the flat 10s default.
        #expect(CreateWorkspaceView.createRequestTimeout == 120)
        #expect(CreateWorkspaceView.createRequestTimeout > ConnectionManager.defaultRequestTimeout)
    }

    @Test func baseRefSentAsPlainBranchName() {
        // Remote branch names from github.branches.list are plain names —
        // no remote-prefix normalization is applied (or expected).
        let params = buildParams(baseRef: "feature/x")
        #expect(params["baseRef"] as? String == "feature/x")
    }

    @Test func noInitialAgentWithoutSpecialistModelOrMessage() {
        let params = buildParams(message: "   \n  ")
        #expect(params["initialAgent"] == nil)
    }

    // MARK: - Optional message (creation without a prompt, matching cloudlands-fe)

    @Test func promptOmittedWithSpecialistAndEmptyMessage() throws {
        // The default flow: a specialist is pre-selected, the message field
        // is left empty — initialAgent is sent without a `prompt` key.
        let params = buildParams(specialist: makeSpecialist(), message: "")
        let initialAgent = try #require(params["initialAgent"] as? [String: Any])
        #expect(initialAgent["specialist"] as? String == "implementor")
        #expect(initialAgent["prompt"] == nil)
    }

    @Test func promptOmittedWithModelPickAndWhitespaceMessage() throws {
        let params = buildParams(model: makeModel(id: "opus4.6"), message: "  \n ")
        let initialAgent = try #require(params["initialAgent"] as? [String: Any])
        #expect(initialAgent["model"] as? String == "opus4.6")
        #expect(initialAgent["prompt"] == nil)
    }

    @Test func initialMessageStartsCompactAndCanGrow() {
        let range = CreateWorkspaceView.initialMessageLineCountRange
        #expect(range.lowerBound == 1)
        #expect(range.upperBound == Constants.CreateWorkspace.messageLineCountRange.upperBound)
    }

    @Test func creationContextCarriesRepositoryIntoBranchAndFinalSteps() {
        let repository = "intent-hq/a-repository-name-that-needs-room-to-wrap"
        let branch = "feature/a-long-branch-name-that-must-remain-complete"
        #expect(
            CreateWorkspaceView.creationContextRows(repositoryFullName: repository) == [
                .init(label: "Repository", value: repository)
            ]
        )
        #expect(
            CreateWorkspaceView.creationContextRows(
                repositoryFullName: repository,
                branch: branch
            ) == [
                .init(label: "Repository", value: repository),
                .init(label: "Branch", value: branch)
            ]
        )
    }

    @Test func creationContextAccessibilityDescriptionsPreserveLabelsAndFullValues() {
        let repository = "intent-hq/a-repository-name-that-needs-room-to-wrap"
        let branch = "feature/a-long-branch-name-that-must-remain-complete"
        let rows = CreateWorkspaceView.creationContextRows(
            repositoryFullName: repository,
            branch: branch
        )
        let descriptions = rows.map(CreateWorkspaceView.creationContextAccessibilityDescription)

        #expect(descriptions == ["Repository: \(repository)", "Branch: \(branch)"])
    }

    @Test func creationContextAccessibilityDescriptionsNameEmptyValues() {
        let rows = CreateWorkspaceView.creationContextRows(
            repositoryFullName: "",
            branch: ""
        )
        let descriptions = rows.map(CreateWorkspaceView.creationContextAccessibilityDescription)

        #expect(descriptions == ["Repository: Not specified", "Branch: Not specified"])
    }

    @Test func creationFormReflowsAtAccessibilitySizes() {
        #expect(!CreateWorkspaceView.usesExpandedFormLayout(for: .xxxLarge))
        #expect(CreateWorkspaceView.usesExpandedFormLayout(for: .accessibility1))
        #expect(CreateWorkspaceView.usesExpandedFormLayout(for: .accessibility5))
    }

    // MARK: - Specialist / prompt / model behavior

    @Test func specialistIdAndTrimmedPromptCarried() throws {
        let params = buildParams(specialist: makeSpecialist(id: "verifier"), message: "  Review the diff  ")
        let initialAgent = try #require(params["initialAgent"] as? [String: Any])
        #expect(initialAgent["specialist"] as? String == "verifier")
        #expect(initialAgent["prompt"] as? String == "Review the diff")
    }

    @Test func modelSentWhenNoSpecialist() throws {
        let params = buildParams(model: makeModel(id: "opus4.6"))
        let initialAgent = try #require(params["initialAgent"] as? [String: Any])
        #expect(initialAgent["model"] as? String == "opus4.6")
        #expect(initialAgent["specialist"] == nil)
    }

    @Test func modelOmittedOnDaemonDefaultSelection() throws {
        // No explicit user pick (model nil): the daemon's resolver decides,
        // even when the specialist carries a resolvedModel preview.
        let params = buildParams(
            specialist: makeSpecialist(resolvedModel: "sonnet4.5", resolvedProvider: "auggie"),
            model: nil,
            message: "Do the thing"
        )
        let initialAgent = try #require(params["initialAgent"] as? [String: Any])
        #expect(initialAgent["model"] == nil)
        #expect(initialAgent["specialist"] as? String == "implementor")
    }

    @Test func modelSentOnExplicitPickWithSpecialist() throws {
        // An explicit pick is always sent as-is, even if it happens to match
        // the daemon's resolved preview — model is non-nil only on user picks.
        let params = buildParams(
            specialist: makeSpecialist(resolvedModel: "sonnet4.5", resolvedProvider: "auggie"),
            model: makeModel(id: "opus4.6")
        )
        let initialAgent = try #require(params["initialAgent"] as? [String: Any])
        #expect(initialAgent["model"] as? String == "opus4.6")
    }

    // MARK: - Provider emission/omission

    @Test func providerOmittedWhenAuggieOnDaemonDefault() throws {
        let params = buildParams(
            specialist: makeSpecialist(resolvedModel: "sonnet4.5", resolvedProvider: "auggie"),
            provider: makeProvider(id: "auggie"),
            model: nil,
            message: "Do the thing"
        )
        let initialAgent = try #require(params["initialAgent"] as? [String: Any])
        #expect(initialAgent["provider"] == nil)
        #expect(initialAgent["model"] == nil)
    }

    @Test func providerOmittedWhenAuggieWithModelPick() throws {
        let params = buildParams(
            specialist: makeSpecialist(),
            provider: makeProvider(id: "auggie"),
            model: makeModel(id: "opus4.6")
        )
        let initialAgent = try #require(params["initialAgent"] as? [String: Any])
        #expect(initialAgent["provider"] == nil)
        #expect(initialAgent["model"] as? String == "opus4.6")
    }

    @Test func nonAuggieProviderAndBareModelSent() throws {
        let params = buildParams(
            specialist: makeSpecialist(),
            provider: makeProvider(id: "claude-code"),
            model: makeModel(id: "claude-sonnet-4-5", provider: "claude-code")
        )
        let initialAgent = try #require(params["initialAgent"] as? [String: Any])
        #expect(initialAgent["provider"] as? String == "claude-code")
        #expect(initialAgent["model"] as? String == "claude-sonnet-4-5")
    }

    @Test func nonAuggieProviderSentWithoutModel() throws {
        let params = buildParams(
            specialist: makeSpecialist(),
            provider: makeProvider(id: "codex"),
            model: nil
        )
        let initialAgent = try #require(params["initialAgent"] as? [String: Any])
        #expect(initialAgent["provider"] as? String == "codex")
        #expect(initialAgent["model"] == nil)
    }

    @Test func nonAuggieProviderAloneCreatesInitialAgent() throws {
        let params = buildParams(provider: makeProvider(id: "codex"))
        let initialAgent = try #require(params["initialAgent"] as? [String: Any])
        #expect(initialAgent["provider"] as? String == "codex")
        #expect(initialAgent["agentId"] == nil)
    }

    @Test func nilProviderOmitsProviderOnWire() throws {
        let params = buildParams(
            specialist: makeSpecialist(),
            provider: nil,
            model: makeModel(id: "sonnet4.5")
        )
        let initialAgent = try #require(params["initialAgent"] as? [String: Any])
        #expect(initialAgent["provider"] == nil)
        #expect(initialAgent["model"] as? String == "sonnet4.5")
    }
}
