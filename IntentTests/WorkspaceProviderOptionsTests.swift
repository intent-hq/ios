import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceProviderOptionsTests {
    private func entry(_ id: String, visible: Bool = true, canBeDisabled: Bool = true) -> [String: Any] {
        ["id": id, "visible": visible, "canBeDisabled": canBeDisabled]
    }

    private func settings(_ enabled: [String: Bool]) -> [String: Any] {
        ["path": "providers.enabled", "value": enabled]
    }

    private func configuredHost(enabled: [String: Bool] = ["codex": true]) -> FakeConnectionManager {
        let fake = FakeConnectionManager()
        fake.responseMap["providers.catalog"] = ["providers": [entry("codex"), entry("auggie")]]
        fake.responseMap["settings.get"] = settings(enabled)
        fake.responseMap["host.providerAuthStatus"] = [
            "providers": [["id": "codex", "authenticated": true], ["id": "auggie", "authenticated": true]]
        ]
        fake.responseMap["specialist.list"] = ["specialists": []]
        return fake
    }

    @Test func filtersHostEnablementAndVisibilityIndependentlyOfAuthentication() async {
        let fake = configuredHost(enabled: [
            "auggie": false, "codex": true, "hidden": true, "always": false, "unknown": true
        ])
        fake.responseMap["providers.catalog"] = [
            "providers": [
                entry("auggie"), entry("unset"), entry("codex"), entry("hidden", visible: false),
                entry("always", canBeDisabled: false), entry("unknown")
            ]
        ]
        fake.responseMap["host.providerAuthStatus"] = [
            "providers": [["id": "auggie", "authenticated": true], ["id": "codex", "authenticated": false]]
        ]
        let options = WorkspaceProviderOptions(connectionManager: fake)
        await options.load()

        #expect(options.providers == [
            ProviderInfo(id: "codex", authenticated: .signedOut),
            ProviderInfo(id: "always", authenticated: .unknown),
            ProviderInfo(id: "unknown", authenticated: .unknown)
        ])
        #expect(!options.providers[0].isSelectable)
        #expect(options.providers[1].isSelectable)
        #expect(fake.paramsForMethod("settings.get").first?["path"] as? String == "providers.enabled")
        #expect(options.guidance == nil)
    }

    @Test func unsetSettingsUseOnlyHostDeclaredAlwaysEnabledProviders() async {
        let fake = configuredHost()
        fake.responseMap["settings.get"] = ["path": "providers.enabled", "value": NSNull()]
        fake.responseMap["providers.catalog"] = [
            "providers": [entry("auggie"), entry("future-provider", canBeDisabled: false)]
        ]
        let options = WorkspaceProviderOptions(connectionManager: fake)
        await options.load()
        #expect(options.providers.map(\.id) == ["future-provider"])
    }

    @Test func noEnabledProvidersShowSetupGuidanceAndClearSelection() async {
        let options = WorkspaceProviderOptions(connectionManager: configuredHost(enabled: [:]))
        await options.load()
        #expect(options.state == .loaded([]))
        #expect(options.guidance?.contains("No providers are enabled") == true)
        #expect(CreationSelectionPolicy.preselectedWorkspaceProvider(
            current: ProviderInfo(id: "auggie"), providers: options.providers
        ) == nil)
        #expect(CreateWorkspaceView.isCreateDisabled(
            isCreating: false, isLoadingProviders: false, providers: options.providers,
            selectedProvider: ProviderInfo(id: "auggie")
        ))
    }

    @Test(arguments: ["providers.catalog", "settings.get", "host.providerAuthStatus"], [false, true])
    func failedColdOrRefreshLoadsHideAllChoices(method: String, warm: Bool) async {
        let fake = configuredHost()
        let options = WorkspaceProviderOptions(connectionManager: fake)
        if warm {
            await options.load()
            #expect(options.providers.map(\.id) == ["codex"])
        }
        fake.errorMap[method] = NSError(domain: "test", code: -1)
        await options.load()
        #expect(options.state == .failed)
        #expect(options.providers.isEmpty)
        #expect(options.guidance?.contains("Retry") == true)
        fake.errorMap[method] = nil
        await options.load()
        #expect(options.providers.map(\.id) == ["codex"])
    }

    @Test func malformedOrUnsupportedPolicyFailsClosed() async {
        let badSettings: [[String: Any]] = [
            [:], ["path": "providers.enabled"], ["path": "wrong", "value": [:]],
            ["path": "providers.enabled", "value": ["codex": 1]],
            ["path": "providers.enabled", "value": ["codex": "true"]]
        ]
        for response in badSettings {
            let fake = configuredHost()
            fake.responseMap["settings.get"] = response
            let options = WorkspaceProviderOptions(connectionManager: fake)
            await options.load()
            #expect(options.state == .failed)
        }
        let badCatalogs: [[String: Any]] = [
            [:], ["providers": [["id": "codex"]]],
            ["providers": [entry("codex"), entry("codex")]],
            ["providers": [entry("")]]
        ]
        for response in badCatalogs {
            let fake = configuredHost()
            fake.responseMap["providers.catalog"] = response
            let options = WorkspaceProviderOptions(connectionManager: fake)
            await options.load()
            #expect(options.state == .failed)
        }
    }

    @Test func refreshHidesChoicesAndReconcilesDisabledSelection() async throws {
        let fake = configuredHost()
        let options = WorkspaceProviderOptions(connectionManager: fake)
        await options.load()
        let previous = options.providers.first
        fake.pendingMethods = ["settings.get"]
        let refresh = Task { await options.load() }
        try await waitUntil("refresh settings read") { fake.paramsForMethod("settings.get").count == 2 }
        #expect(options.isLoading)
        #expect(options.providers.isEmpty)
        #expect(CreateWorkspaceView.isCreateDisabled(
            isCreating: false, isLoadingProviders: options.isLoading,
            providers: options.providers, selectedProvider: previous
        ))
        fake.resolvePending("settings.get", with: settings(["auggie": true]))
        await refresh.value
        let selection = CreationSelectionPolicy.preselectedWorkspaceProvider(current: previous, providers: options.providers)
        #expect(selection?.id == "auggie")
        #expect(CreateWorkspaceView.isCreateDisabled(
            isCreating: false, isLoadingProviders: false,
            providers: options.providers, selectedProvider: previous
        ))
        #expect(!CreateWorkspaceView.isCreateDisabled(
            isCreating: false, isLoadingProviders: false,
            providers: options.providers, selectedProvider: selection
        ))
    }

    @Test func concurrentLoadsJoinAndInvalidationRejectsOldCompletion() async throws {
        let fake = configuredHost()
        fake.pendingMethods = ["settings.get"]
        let options = WorkspaceProviderOptions(connectionManager: fake)
        let oldLoad = Task { await options.load() }
        try await waitUntil("old settings read") { fake.paramsForMethod("settings.get").count == 1 }
        var joining = false
        let joined = Task {
            joining = true
            await options.load()
        }
        try await waitUntil("concurrent caller joins") { joining }
        options.invalidate()
        let freshLoad = Task { await options.load() }
        try await waitUntil("fresh settings read") { fake.paramsForMethod("settings.get").count == 2 }
        fake.resolvePending("settings.get", with: settings(["codex": true]))
        await oldLoad.value
        await joined.value
        #expect(options.state == .loading)
        #expect(options.providers.isEmpty)
        fake.resolvePending("settings.get", with: settings(["auggie": true]))
        await freshLoad.value
        #expect(options.providers.map(\.id) == ["auggie"])
        #expect(fake.paramsForMethod("providers.catalog").count == 2)
    }

    @Test func reconnectClearsWorkspacePolicyAndKeepsHostsIsolated() async throws {
        let firstHost = configuredHost()
        let first = CreationOptionsStore(connectionManager: firstHost)
        let second = CreationOptionsStore(connectionManager: configuredHost(enabled: ["auggie": true]))
        await first.workspaceProviderOptions.load()
        await second.workspaceProviderOptions.load()
        firstHost.simulateDisconnect()
        try await waitUntil("disconnected policy clear") { first.workspaceProviderOptions.state == .idle }
        #expect(first.workspaceProviderOptions.providers.isEmpty)
        #expect(second.workspaceProviderOptions.providers.map(\.id) == ["auggie"])
        firstHost.responseMap["settings.get"] = settings([:])
        firstHost.simulateConnect()
        try await waitUntil("reconnected policy load") { first.workspaceProviderOptions.state == .loaded([]) }
        #expect(second.workspaceProviderOptions.providers.map(\.id) == ["auggie"])
        #expect(!firstHost.didCallMethod("specialist.list"))
    }

    @Test func workspacePolicyDoesNotFilterSharedAgentProvidersOrModels() async {
        let fake = configuredHost(enabled: [:])
        fake.responseMap["models.list"] = ["models": [["id": "model", "name": "Model", "provider": "codex"]]]
        let store = CreationOptionsStore(connectionManager: fake)
        await store.loadIfNeeded()
        #expect(!fake.didCallMethod("providers.catalog"))
        #expect(!fake.didCallMethod("settings.get"))
        await store.workspaceProviderOptions.load()
        await store.loadModelsIfNeeded(providerId: "codex")
        #expect(store.workspaceProviderOptions.providers.isEmpty)
        #expect(store.providers.map(\.id) == ["codex", "auggie"])
        #expect(store.models(for: "codex")?.map(\.id) == ["model"])
    }
}
