import Foundation
@testable import Intent
import Testing

/// Tests for the shared provider/model catalog helpers on AgentStore:
/// host.providerAuthStatus parsing, models.list parsing, and the
/// provider/model params on agent.create.
@MainActor
struct ProviderCatalogTests {
    // MARK: - fetchProviders (host.providerAuthStatus)

    @Test func fetchProvidersParsesTriStateAuthenticated() async {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake)
        fake.responseMap["host.providerAuthStatus"] = [
            "providers": [
                ["id": "auggie", "authenticated": true],
                ["id": "claude-code", "authenticated": false],
                ["id": "grok", "authenticated": NSNull()],
                ["id": "pi"]
            ]
        ]

        let providers = await store.fetchProviders()

        #expect(providers.count == 4)
        #expect(providers[0] == ProviderInfo(id: "auggie", authenticated: true))
        #expect(providers[1] == ProviderInfo(id: "claude-code", authenticated: false))
        #expect(providers[2] == ProviderInfo(id: "grok", authenticated: .unknown))
        #expect(providers[3] == ProviderInfo(id: "pi", authenticated: .unknown))
        #expect(fake.didCallMethod("host.providerAuthStatus"))
    }

    @Test func fetchProvidersSkipsEntriesWithoutIdAndReturnsEmptyOnError() async {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake)
        fake.responseMap["host.providerAuthStatus"] = [
            "providers": [
                ["authenticated": true],
                ["id": "codex", "authenticated": true]
            ]
        ]
        #expect(await store.fetchProviders() == [ProviderInfo(id: "codex", authenticated: true)])

        fake.errorMap["host.providerAuthStatus"] = NSError(domain: "test", code: -1)
        #expect(await store.fetchProviders().isEmpty)
    }

    @Test func providerDisplayNames() {
        #expect(ProviderInfo.displayName(for: "auggie") == "Auggie")
        #expect(ProviderInfo.displayName(for: "claude-code") == "Claude Code")
        #expect(ProviderInfo.displayName(for: "codex") == "Codex")
        #expect(ProviderInfo.displayName(for: "opencode") == "OpenCode")
        #expect(ProviderInfo.displayName(for: "droid") == "Droid")
        #expect(ProviderInfo.displayName(for: "grok") == "Grok")
        #expect(ProviderInfo.displayName(for: "pi") == "Pi")
        #expect(ProviderInfo.displayName(for: "gemini") == "Gemini")
        #expect(ProviderInfo(id: "grok", authenticated: .unknown).displayName == "Grok")
    }

    // MARK: - fetchModels (models.list)

    @Test func fetchModelsSendsProviderIdAndParsesModels() async {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake)
        fake.responseMap["models.list"] = [
            "providerId": "auggie",
            "source": "auggie",
            "models": [
                ["id": "sonnet4.5", "name": "Sonnet 4.5", "provider": "auggie", "isDefault": true],
                ["id": "haiku4.5", "name": "Haiku 4.5", "provider": "auggie"],
                ["name": "missing id"]
            ]
        ]

        let models = await store.fetchModels(providerId: "auggie")

        let params = fake.paramsForMethod("models.list")
        #expect(params.count == 1)
        #expect(params[0]["providerId"] as? String == "auggie")

        #expect(models.count == 2)
        #expect(models[0].id == "sonnet4.5")
        #expect(models[0].name == "Sonnet 4.5")
        #expect(models[0].provider == "auggie")
        #expect(models[0].isDefault == true)
        #expect(models[1].id == "haiku4.5")
        #expect(models[1].isDefault == false)
    }

    @Test func fetchModelsDefaultsProviderToRequestedIdAndReturnsEmptyOnError() async {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake)
        fake.responseMap["models.list"] = [
            "models": [["id": "grok-4", "name": "Grok 4"]]
        ]
        let models = await store.fetchModels(providerId: "grok")
        #expect(models.count == 1)
        #expect(models[0].provider == "grok")

        fake.errorMap["models.list"] = NSError(domain: "test", code: -1)
        #expect(await store.fetchModels(providerId: "grok").isEmpty)
    }

    // MARK: - createAgent provider/model params (agent.create)

    private func configureCreateAgent(_ fake: FakeConnectionManager) {
        fake.responseMap["agent.create"] = [
            "agent": ["id": "agent-1", "name": "Implementor"]
        ]
        fake.responseMap["agent.list"] = ["agents": [] as [[String: Any]]]
    }

    @Test func createAgentIncludesProviderAndModelWhenSet() async throws {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake)
        configureCreateAgent(fake)

        let agent = try await store.createAgent(
            workspaceId: "ws-1",
            specialistId: "implementor",
            provider: "claude-code",
            model: "opus-4.5"
        )

        #expect(agent?.id == "agent-1")
        let params = fake.paramsForMethod("agent.create")
        #expect(params.count == 1)
        #expect(params[0]["workspaceId"] as? String == "ws-1")
        #expect(params[0]["specialistId"] as? String == "implementor")
        #expect(params[0]["provider"] as? String == "claude-code")
        #expect(params[0]["model"] as? String == "opus-4.5")
    }

    @Test func createAgentOmitsProviderAndModelWhenNil() async throws {
        let fake = FakeConnectionManager()
        let store = AgentStore(connectionManager: fake)
        configureCreateAgent(fake)

        _ = try await store.createAgent(workspaceId: "ws-1", specialistId: nil)

        let params = fake.paramsForMethod("agent.create")
        #expect(params.count == 1)
        #expect(params[0]["provider"] == nil)
        #expect(params[0]["model"] == nil)
        #expect(params[0]["specialistId"] == nil)
    }
}
