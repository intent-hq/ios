import Testing
@testable import Intent

struct CreateWorkspaceParamsTests {
    private func makeSpecialist(id: String = "implementor", model: String? = nil) -> SpecialistInfo {
        SpecialistInfo(id: id, name: "Implementor", description: "Implements tasks", modelTier: "balanced", model: model)
    }

    private func makeModel(id: String = "sonnet4.5") -> ModelInfo {
        ModelInfo(id: id, name: "\(id) (balanced)", provider: "auggie")
    }

    private func buildParams(
        specialist: SpecialistInfo? = nil,
        model: ModelInfo? = nil,
        message: String = ""
    ) -> [String: Any] {
        CreateWorkspaceView.buildCreateWorkspaceParams(
            repositoryPath: "/repos/example",
            baseRef: "main",
            idempotencyKey: "key-123",
            specialist: specialist,
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
}
