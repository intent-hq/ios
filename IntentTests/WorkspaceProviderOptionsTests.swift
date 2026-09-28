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

    private func configuredHost(enabled: [String: Bool] = ["codex": true]) -> RPCRecordingConnection {
        let fake = RPCRecordingConnection()
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
            isCreating: false,
            isLoadingProviders: false,
            providers: options.providers,
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

    @Test(arguments: ["unchanged", "disabled", "signed-out", "empty"])
    func refreshReconcilesDraftOnlyAfterPolicySettles(outcome: String) async throws {
        let fake = configuredHost(enabled: ["codex": true, "auggie": true])
        let options = WorkspaceProviderOptions(connectionManager: fake)
        await options.load()
        let pickedProvider = ProviderInfo(id: "codex", authenticated: .signedIn)
        let pickedModel = ModelInfo(id: "named-model", name: "Named Model", provider: "codex")
        var provider: ProviderInfo? = pickedProvider
        var model: ModelInfo? = pickedModel
        CreationSelectionPolicy.reconcileWorkspaceProvider(provider: &provider, model: &model, state: options.state)
        #expect(provider == pickedProvider)
        #expect(model == pickedModel)
        if outcome == "signed-out" {
            fake.responseMap["host.providerAuthStatus"] = [
                "providers": [["id": "codex", "authenticated": false], ["id": "auggie", "authenticated": true]]
            ]
        }
        fake.pendingMethods = ["settings.get"]
        let refresh = Task { await options.load() }
        try await fake.waitForPendingRequests("settings.get")
        expectPendingDraft(options, provider: &provider, model: &model)
        let enabled = outcome == "empty" ? [:] : ["auggie": true, "codex": outcome != "disabled"]
        fake.resolvePending("settings.get", with: settings(enabled))
        await refresh.value
        #expect(options.state == .loaded(options.providers))
        CreationSelectionPolicy.reconcileWorkspaceProvider(provider: &provider, model: &model, state: options.state)
        let expectedProvider = outcome == "empty" ? nil : ProviderInfo(
            id: outcome == "unchanged" ? "codex" : "auggie", authenticated: .signedIn
        )
        #expect(provider == expectedProvider)
        #expect(model == (outcome == "unchanged" ? pickedModel : nil))
        #expect(CreateWorkspaceView.isCreateDisabled(
            isCreating: false,
            isLoadingProviders: options.isLoading,
            providers: options.providers,
            selectedProvider: provider
        ) == (outcome == "empty"))
        #expect(CreateWorkspaceView.isCreateDisabled(
            isCreating: false,
            isLoadingProviders: options.isLoading,
            providers: options.providers,
            selectedProvider: pickedProvider
        ) == (outcome != "unchanged"))
    }

    @Test(arguments: ["providers.catalog", "settings.get", "host.providerAuthStatus"])
    func failedRefreshClearsDraftAndRetryRevalidatesSelection(method: String) async throws {
        let fake = configuredHost(enabled: ["codex": true, "auggie": true])
        let options = WorkspaceProviderOptions(connectionManager: fake)
        await options.load()
        var provider: ProviderInfo? = ProviderInfo(id: "codex", authenticated: .signedIn)
        var model: ModelInfo? = ModelInfo(id: "named-model", name: "Named Model", provider: "codex")
        CreationSelectionPolicy.reconcileWorkspaceProvider(provider: &provider, model: &model, state: options.state)
        fake.pendingMethods = [method]
        let refresh = Task { await options.load() }
        try await fake.waitForPendingRequests(method)
        expectPendingDraft(options, provider: &provider, model: &model)
        fake.failPending(method, with: NSError(domain: "test", code: -1))
        await refresh.value
        #expect(options.state == .failed)
        CreationSelectionPolicy.reconcileWorkspaceProvider(provider: &provider, model: &model, state: options.state)
        #expect(provider == nil)
        #expect(model == nil)
        #expect(options.providers.isEmpty)
        #expect(CreateWorkspaceView.isCreateDisabled(
            isCreating: false,
            isLoadingProviders: options.isLoading,
            providers: options.providers,
            selectedProvider: ProviderInfo(id: "codex")
        ))
        let retry = Task { await options.load() }
        try await fake.waitForPendingRequests(method)
        expectPendingDraft(options, provider: &provider, model: &model)
        fake.resolvePending(method, with: try #require(fake.responseMap[method]))
        await retry.value
        CreationSelectionPolicy.reconcileWorkspaceProvider(provider: &provider, model: &model, state: options.state)
        #expect(provider == ProviderInfo(id: "auggie", authenticated: .signedIn))
        #expect(model == nil)
        #expect(!CreateWorkspaceView.isCreateDisabled(
            isCreating: false,
            isLoadingProviders: options.isLoading,
            providers: options.providers,
            selectedProvider: provider
        ))
    }

    private func expectPendingDraft(
        _ options: WorkspaceProviderOptions, provider: inout ProviderInfo?, model: inout ModelInfo?
    ) {
        let previousProvider = provider
        let previousModel = model
        #expect(options.state == .loading)
        CreationSelectionPolicy.reconcileWorkspaceProvider(provider: &provider, model: &model, state: options.state)
        #expect(provider == previousProvider)
        #expect(model == previousModel)
        #expect(options.isLoading)
        #expect(options.providers.isEmpty)
        #expect(CreateWorkspaceView.isCreateDisabled(
            isCreating: false,
            isLoadingProviders: options.isLoading,
            providers: options.providers,
            selectedProvider: provider
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
        let secondHost = configuredHost(enabled: ["auggie": true])
        firstHost.simulateConnect()
        secondHost.simulateConnect()
        let first = CreationOptionsStore(connectionManager: firstHost)
        let second = CreationOptionsStore(connectionManager: secondHost)
        let consumer = UUID()
        defer {
            first.releaseCatalogs(consumer: consumer)
            second.releaseCatalogs(consumer: consumer)
            first.reset()
            second.reset()
        }
        await loadWorkspacePicker(first, consumer: consumer)
        await loadWorkspacePicker(second, consumer: consumer)
        let checkpoint = firstHost.checkpoint
        let isolated = secondHost.checkpoint
        firstHost.simulateDisconnect()
        try await waitUntil("disconnected policy clear") { first.workspaceProviderOptions.state == .idle }
        #expect(first.workspaceProviderOptions.providers.isEmpty)
        #expect(second.workspaceProviderOptions.providers.map(\.id) == ["auggie"])
        #expect(firstHost.traffic(since: checkpoint).requests.isEmpty)
        firstHost.responseMap["settings.get"] = settings([:])
        firstHost.simulateConnect()
        try await waitUntil("reconnected picker load") {
            first.workspaceProviderOptions.state == .loaded([]) && first.hasLoaded && firstHost.traffic().pendingCount == 0
        }
        #expect(second.workspaceProviderOptions.providers.map(\.id) == ["auggie"])
        #expect(secondHost.traffic(since: isolated).requests.isEmpty)
        #expect(firstHost.traffic(since: checkpoint).methodCounts == [
            "specialist.list": 1, "host.providerAuthStatus": 2, "providers.catalog": 1, "settings.get": 1
        ])
        printCatalogLedger("workspace-picker-active-reconnect", firstHost.traffic(since: checkpoint))
        first.releaseCatalogs(consumer: consumer)
        let released = firstHost.checkpoint
        firstHost.simulateDisconnect()
        firstHost.simulateConnect()
        try await expectNever("closed picker reconnect discovery") { !firstHost.traffic(since: released).requests.isEmpty }
        #expect(first.workspaceProviderOptions.state == .idle)
        printCatalogLedger("workspace-picker-released-reconnect", firstHost.traffic(since: released))
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

extension WorkspaceProviderOptionsTests {
    private func loadWorkspacePicker(_ store: CreationOptionsStore, consumer: UUID) async {
        store.retainCreationOptions(consumer: consumer)
        async let policy: () = store.workspaceProviderOptions.load()
        await store.loadIfNeeded(consumer: consumer)
        await policy
    }

    @Test func workspacePolicyReconnectWithOnlyLabelsDoesNotDiscoverProviders() async throws {
        let connection = configuredHost()
        connection.simulateConnect()
        let store = CreationOptionsStore(connectionManager: connection)
        defer { store.reset() }
        let consumer = UUID()
        store.retainSpecialists(consumer: consumer)
        await store.ensureSpecialists(consumer: consumer)
        // A previously opened workspace picker does not retain a creation
        // interest merely because its policy was loaded on this session.
        await store.workspaceProviderOptions.load()
        let checkpoint = connection.checkpoint
        connection.simulateDisconnect()
        connection.simulateConnect()
        try await waitUntil("interested labels refreshed") { store.specialistCatalog.isFresh }
        try await expectNever("label-only reconnect provider discovery") {
            connection.traffic(since: checkpoint).requests.contains { $0.method != "specialist.list" }
        }
        #expect(connection.traffic(since: checkpoint).methodCounts == ["specialist.list": 1])
        #expect(store.workspaceProviderOptions.state == .idle)
        printCatalogLedger("workspace-policy-label-only-reconnect", connection.traffic(since: checkpoint))
        store.releaseCatalogs(consumer: consumer)
        let inactive = connection.checkpoint
        CreationOptionsStoreTests().catalogEvent(connection, type: "settings:changed", paths: ["providers.enabled"])
        CreationOptionsStoreTests().catalogEvent(connection, type: "specialists:changed")
        connection.simulateDisconnect()
        connection.simulateConnect()
        try await expectNever("inactive policy/catalog discovery") { !connection.traffic(since: inactive).requests.isEmpty }
        #expect(store.workspaceProviderOptions.state == .idle)
        printCatalogLedger("workspace-policy-inactive-events-and-reconnect", connection.traffic(since: inactive))
    }

    @Test func demoCreationFixturesLoadSelectableProvidersAndNamedModels() async {
        let fake = FakeConnectionManager()
        for method in ["providers.catalog", "host.providerAuthStatus", "specialist.list"] {
            fake.responseMap[method] = DemoFixtures.response(for: method, params: [:])
        }
        fake.responseMap["settings.get"] = DemoFixtures.response(for: "settings.get", params: ["path": "providers.enabled"])
        fake.responseMap["models.list"] = DemoFixtures.response(for: "models.list", params: ["providerId": "codex"])
        let store = CreationOptionsStore(connectionManager: fake)
        await store.workspaceProviderOptions.load()
        await store.loadModelsIfNeeded(providerId: "codex")
        #expect(store.workspaceProviderOptions.providers.map(\.id) == ["auggie", "codex"])
        let allSelectable = store.workspaceProviderOptions.providers.allSatisfy(\.isSelectable)
        #expect(allSelectable)
        #expect(store.models(for: "codex")?.last == ModelInfo(
            id: "named-model", name: "Named Model", provider: "codex", effortLevels: ["low", "medium", "high"]
        ))
    }

    @Test func demoProviderGateIsOptInAndDoesNotPermitWorkspaceCreation() throws {
        #expect(DemoFixtures.workspaceProviderGate(from: ["--demo-data"]) == nil)
        #expect(DemoFixtures.workspaceProviderGate(from: ["--demo-workspace-provider-trigger-file="]) == nil)
        #expect(DemoFixtures.workspaceProviderGate(from: ["--demo-workspace-provider-trigger-file=/tmp/provider.trigger"])
            == .triggerFile(URL(fileURLWithPath: "/tmp/provider.trigger")))
        #expect(DemoFixtures.responseGate(for: "settings.get", params: ["path": "providers.enabled"]) == nil)
        let create = try #require(DemoFixtures.response(for: "workspace.create", params: [:]) as? [String: Any])
        #expect(create.isEmpty)
    }
}
