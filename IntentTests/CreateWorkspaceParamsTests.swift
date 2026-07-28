import Testing
@testable import Intent

struct CreateWorkspaceParamsTests {
    private func makeSpecialist(id: String = "implementor", model: String? = nil) -> SpecialistInfo {
        SpecialistInfo(id: id, name: "Implementor", description: "Implements tasks", modelTier: "balanced", model: model)
    }

    private func makeModel(id: String = "sonnet4.5", provider: String = "auggie") -> ModelInfo {
        ModelInfo(id: id, name: "\(id) (balanced)", provider: provider)
    }

    private func makeProvider(id: String = "auggie", authenticated: Bool? = true) -> ProviderInfo {
        ProviderInfo(id: id, authenticated: authenticated)
    }

    private func buildParams(
        specialist: SpecialistInfo? = nil,
        provider: ProviderInfo? = nil,
        model: ModelInfo? = nil,
        message: String = ""
    ) -> [String: Any] {
        CreateWorkspaceView.buildCreateWorkspaceParams(
            repositoryPath: "/repos/example",
            baseRef: "main",
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

    // MARK: - Base params

    @Test func baseParamsAlwaysPresent() {
        let params = buildParams()
        #expect(params["repositoryPath"] as? String == "/repos/example")
        #expect(params["baseRef"] as? String == "main")
        #expect(params["idempotencyKey"] as? String == "key-123")
    }

    @Test func noInitialAgentWithoutSpecialistModelOrMessage() {
        let params = buildParams(message: "   \n  ")
        #expect(params["initialAgent"] == nil)
    }

    // MARK: - Specialist / prompt / model behavior preserved

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

    @Test func modelOmittedWhenMatchingSpecialistConfiguredModel() throws {
        let params = buildParams(specialist: makeSpecialist(model: "sonnet4.5"), model: makeModel(id: "sonnet4.5"))
        let initialAgent = try #require(params["initialAgent"] as? [String: Any])
        #expect(initialAgent["model"] == nil)
    }

    @Test func modelSentWhenOverridingSpecialistConfiguredModel() throws {
        let params = buildParams(specialist: makeSpecialist(model: "sonnet4.5"), model: makeModel(id: "opus4.6"))
        let initialAgent = try #require(params["initialAgent"] as? [String: Any])
        #expect(initialAgent["model"] as? String == "opus4.6")
    }

    @Test func modelOmittedWhenSpecialistHasNoConfiguredModel() throws {
        let params = buildParams(specialist: makeSpecialist(model: nil), model: makeModel(id: "sonnet4.5"))
        let initialAgent = try #require(params["initialAgent"] as? [String: Any])
        #expect(initialAgent["model"] == nil)
        #expect(initialAgent["specialist"] as? String == "implementor")
    }

    // MARK: - Provider emission/omission

    @Test func providerOmittedWhenAuggieAndModelMatchesConfigured() throws {
        let params = buildParams(
            specialist: makeSpecialist(model: "sonnet4.5"),
            provider: makeProvider(id: "auggie"),
            model: makeModel(id: "sonnet4.5")
        )
        let initialAgent = try #require(params["initialAgent"] as? [String: Any])
        #expect(initialAgent["provider"] == nil)
        #expect(initialAgent["model"] == nil)
    }

    @Test func providerOmittedWhenAuggieWithModelOverride() throws {
        let params = buildParams(
            specialist: makeSpecialist(model: "sonnet4.5"),
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

    @Test func nonAuggieProviderSentEvenWhenModelMatchesConfigured() throws {
        let params = buildParams(
            specialist: makeSpecialist(model: "sonnet4.5"),
            provider: makeProvider(id: "codex"),
            model: makeModel(id: "sonnet4.5", provider: "codex")
        )
        let initialAgent = try #require(params["initialAgent"] as? [String: Any])
        #expect(initialAgent["provider"] as? String == "codex")
        #expect(initialAgent["model"] as? String == "sonnet4.5")
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

    @Test func nilProviderPreservesOmissionBehavior() throws {
        let params = buildParams(
            specialist: makeSpecialist(model: "sonnet4.5"),
            provider: nil,
            model: makeModel(id: "sonnet4.5")
        )
        let initialAgent = try #require(params["initialAgent"] as? [String: Any])
        #expect(initialAgent["provider"] == nil)
        #expect(initialAgent["model"] == nil)
    }

    // MARK: - modelFetchOutcome (stale-response guard)

    @Test func modelFetchOutcomeDropsStaleProviderResults() {
        // Provider A's catalog must not apply after the user switched to B.
        let outcome = CreateWorkspaceView.modelFetchOutcome(
            fetched: [makeModel(id: "grok-4", provider: "grok")],
            requestedProviderId: "grok",
            selectedProviderId: "claude-code",
            specialist: makeSpecialist()
        )
        #expect(outcome == nil)
    }

    @Test func modelFetchOutcomeAppliesAuggieTierSelection() throws {
        let fetched = [makeModel(id: "sonnet4.5"), makeModel(id: "opus4.6")]
        let outcome = try #require(CreateWorkspaceView.modelFetchOutcome(
            fetched: fetched,
            requestedProviderId: "auggie",
            selectedProviderId: "auggie",
            specialist: makeSpecialist(model: "opus4.6")
        ))
        #expect(outcome.models.map(\.id) == ["sonnet4.5", "opus4.6"])
        #expect(outcome.selectedModel?.id == "opus4.6")
    }

    @Test func modelFetchOutcomeAppliesProviderDefaultForNonAuggie() throws {
        let fetched = [
            makeModel(id: "opus-4.5", provider: "claude-code"),
            ModelInfo(id: "sonnet-4.6", name: "sonnet-4.6", provider: "claude-code", isDefault: true)
        ]
        let outcome = try #require(CreateWorkspaceView.modelFetchOutcome(
            fetched: fetched,
            requestedProviderId: "claude-code",
            selectedProviderId: "claude-code",
            specialist: makeSpecialist()
        ))
        #expect(outcome.selectedModel?.id == "sonnet-4.6")
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
}
