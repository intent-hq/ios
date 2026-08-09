import Testing
@testable import Intent

struct CreateWorkspaceParamsTests {
    private func makeSpecialist(
        id: String = "implementor",
        resolvedModel: String? = nil,
        resolvedProvider: String? = nil
    ) -> SpecialistInfo {
        SpecialistInfo(
            id: id, name: "Implementor", description: "Implements tasks",
            resolvedModel: resolvedModel, resolvedProvider: resolvedProvider
        )
    }

    private func makeModel(id: String = "sonnet4.5", provider: String = "auggie") -> ModelInfo {
        ModelInfo(id: id, name: "\(id) (balanced)", provider: provider)
    }

    private func makeProvider(id: String = "auggie", authenticated: Bool? = true) -> ProviderInfo {
        ProviderInfo(id: id, authenticated: authenticated)
    }

    private func buildParams(
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

    // MARK: - modelFetchOutcome (stale-response guard)

    @Test func modelFetchOutcomeDropsStaleProviderResults() {
        // Provider A's catalog must not apply after the user switched to B.
        let outcome = CreateWorkspaceView.modelFetchOutcome(
            fetched: [makeModel(id: "grok-4", provider: "grok")],
            requestedProviderId: "grok",
            selectedProviderId: "claude-code"
        )
        #expect(outcome == nil)
    }

    @Test func modelFetchOutcomeResetsToDaemonDefaultRow() throws {
        // A fresh catalog resets the selection to the daemon-default row (nil)
        // — the daemon's resolver decides unless the user explicitly picks.
        let fetched = [makeModel(id: "sonnet4.5"), makeModel(id: "opus4.6")]
        let outcome = try #require(CreateWorkspaceView.modelFetchOutcome(
            fetched: fetched,
            requestedProviderId: "auggie",
            selectedProviderId: "auggie"
        ))
        #expect(outcome.models.map(\.id) == ["sonnet4.5", "opus4.6"])
        #expect(outcome.selectedModel == nil)
    }

    // MARK: - isCreateDisabled (Create unavailable in the guidance state, monorepo#1003)

    private func isCreateDisabled(
        isCreating: Bool = false,
        isLoadingProviders: Bool = false,
        providers: [ProviderInfo]
    ) -> Bool {
        CreateWorkspaceView.isCreateDisabled(
            isCreating: isCreating,
            isLoadingProviders: isLoadingProviders,
            providers: providers
        )
    }

    @Test func createDisabledWhenNoProviderSelectable() {
        let providers = [
            makeProvider(id: "auggie", authenticated: false),
            makeProvider(id: "codex", authenticated: false),
        ]
        #expect(isCreateDisabled(providers: providers))
    }

    @Test func createEnabledWhenAProviderIsSelectable() {
        #expect(!isCreateDisabled(providers: [makeProvider()]))
        // nil (unknown) stays selectable since probes can fail transiently
        #expect(!isCreateDisabled(providers: [makeProvider(id: "grok", authenticated: nil)]))
    }

    @Test func createEnabledWhenProviderListEmptyAfterLoad() {
        // Empty list after load is not the guidance state: the daemon default is used
        #expect(!isCreateDisabled(providers: []))
    }

    @Test func createDisabledWhileCreatingOrLoadingProviders() {
        #expect(isCreateDisabled(isCreating: true, providers: [makeProvider()]))
        // An empty in-flight list can't be told apart from a seat with no providers
        #expect(isCreateDisabled(isLoadingProviders: true, providers: []))
    }

    // MARK: - preselectedBranch

    @Test func preselectedBranchKeepsStillValidSelection() {
        #expect(CreateWorkspaceView.preselectedBranch(
            current: "dev", branches: ["main", "dev"], defaultBranch: "main"
        ) == "dev")
    }

    @Test func preselectedBranchPrefersDefaultWhenSelectionInvalid() {
        #expect(CreateWorkspaceView.preselectedBranch(
            current: nil, branches: ["dev", "main"], defaultBranch: "main"
        ) == "main")
        // A stale selection from a previously picked repo is dropped
        #expect(CreateWorkspaceView.preselectedBranch(
            current: "feature/x", branches: ["dev", "main"], defaultBranch: "main"
        ) == "main")
    }

    @Test func preselectedBranchFallsBackToFirstBranch() {
        #expect(CreateWorkspaceView.preselectedBranch(
            current: nil, branches: ["dev", "main"], defaultBranch: nil
        ) == "dev")
        #expect(CreateWorkspaceView.preselectedBranch(
            current: nil, branches: [], defaultBranch: "main"
        ) == nil)
    }
}
