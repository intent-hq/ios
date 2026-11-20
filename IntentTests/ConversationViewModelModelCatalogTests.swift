import Foundation
@testable import Intent
import Testing

// swiftlint:disable identifier_name large_tuple
// swiftlint:disable no_magic_numbers

extension ConversationViewModelTests {
    @Test func changingModelWithHistoryWaitsForConfirmationAndPreservesDraft() async throws {
        let (vm, _, fake) = makeCatalogVM()
        vm.currentModelId = "sonnet4.5"
        vm.store.messages = [textMessage(role: .user, text: "Existing conversation")]
        vm.messageText = "Continue with this draft"
        let messageIds = vm.filteredMessageIDs
        fake.pendingMethods = ["agent.setModel"]

        let change = Task { try await vm.setModel("opus") }
        try await waitUntil("model change request") { fake.didCallMethod("agent.setModel") }
        #expect(vm.currentModelId == "sonnet4.5")
        let params = try #require(fake.paramsForMethod("agent.setModel").first)
        #expect(params["agentId"] as? String == "test-agent")
        #expect(params["workspaceId"] as? String == "test-ws")
        #expect(params["modelId"] as? String == "opus")

        fake.resolvePending("agent.setModel", with: ["success": true])
        try await change.value
        #expect(vm.currentModelId == "opus")
        #expect(vm.messageText == "Continue with this draft")
        #expect(vm.filteredMessageIDs == messageIds)
    }

    @Test func failedModelChangeKeepsSelectionAndCanBeRetried() async throws {
        let (vm, _, fake) = makeCatalogVM()
        vm.currentModelId = "sonnet4.5"
        let expectedError = NSError(domain: "ModelChange", code: -1)
        fake.errorMap["agent.setModel"] = expectedError

        do {
            try await vm.setModel("opus")
            Issue.record("A failed model change must reach the picker")
        } catch {
            #expect(error as NSError == expectedError)
        }
        #expect(vm.currentModelId == "sonnet4.5")

        fake.errorMap["agent.setModel"] = nil
        fake.responseMap["agent.setModel"] = ["success": true]
        try await vm.setModel("opus")
        #expect(vm.currentModelId == "opus")
    }

    @Test func modelDisplayNameResolvesNameFromCatalog() {
        let catalog = [
            ModelInfo(id: "sonnet4.5", name: "Sonnet 4.5 (balanced)", provider: "auggie"),
            ModelInfo(id: "sonnet4.5", name: "Sonnet 4.5 via Grok", provider: "grok")
        ]
        #expect(
            ConversationViewModel.modelDisplayName(
                modelId: "sonnet4.5", provider: "grok", catalog: catalog
            )
                == "Sonnet 4.5 via Grok"
        )
        #expect(
            ConversationViewModel.modelDisplayName(
                modelId: "sonnet4.5", provider: nil, catalog: catalog
            )
                == "Sonnet 4.5 (balanced)"
        )
    }

    @Test func modelDisplayNameFallsBackToIdWhenCatalogEmptyOrMissesId() {
        let catalog = [ModelInfo(id: "opus", name: "Opus", provider: "auggie")]
        #expect(
            ConversationViewModel.modelDisplayName(
                modelId: "sonnet4.5", provider: "auggie", catalog: []
            )
                == "sonnet4.5"
        )
        #expect(
            ConversationViewModel.modelDisplayName(
                modelId: "sonnet4.5", provider: "auggie", catalog: catalog
            )
                == "sonnet4.5"
        )
        #expect(
            ConversationViewModel.modelDisplayName(
                modelId: "opus", provider: "grok", catalog: catalog
            )
                == "opus"
        )
    }

    private func makeCatalogVM() -> (vm: ConversationViewModel, store: CreationOptionsStore, fake: FakeConnectionManager) {
        let fake = FakeConnectionManager()
        fake.responseMap["models.list"] = [
            "models": [
                ["id": "sonnet4.5", "name": "Sonnet 4.5 (balanced)", "provider": "auggie"]
            ]
        ]
        fake.responseMap["agent.get"] = ["agent": ["model": "sonnet4.5", "provider": "auggie"]]
        let store = CreationOptionsStore(connectionManager: fake)
        let vm = ConversationViewModel(
            agentId: "test-agent",
            workspaceId: "test-ws",
            agentName: "Test",
            connection: fake,
            uploadService: AttachmentUploadService(connection: fake),
            optionsStore: store
        )
        return (vm, store, fake)
    }

    private func waitFor(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for \(description)")
    }

    @Test func currentModelDisplayNameReadsSharedProviderCatalog() async {
        let (vm, _, fake) = makeCatalogVM()
        vm.currentModelId = "sonnet4.5"
        vm.currentProviderId = "auggie"

        #expect(vm.selectableModels == nil)
        #expect(vm.currentModelDisplayName == "sonnet4.5")
        #expect(vm.modelCatalogKey == .init(providerId: "auggie", isCached: false, loadGeneration: 0))

        await vm.loadModelCatalogIfNeeded()

        #expect(vm.currentModelDisplayName == "Sonnet 4.5 (balanced)")
        #expect(vm.selectableModels?.map(\.id) == ["sonnet4.5"])
        #expect(vm.modelCatalogKey == .init(providerId: "auggie", isCached: true, loadGeneration: 0))

        let requestsAfterLoad = fake.requestLog.count
        await vm.loadModelCatalogIfNeeded()
        #expect(fake.requestLog.count == requestsAfterLoad)
    }

    @Test func reconnectDuringColdCatalogLoadBumpsKeyAndReloadsFresh() async throws {
        let (vm, store, fake) = makeCatalogVM()
        await vm.fetchCurrentModel()
        fake.pendingMethods = ["models.list"]
        let load = Task { await vm.loadModelCatalogIfNeeded() }
        try await waitFor("cold models.list") { fake.didCallMethod("models.list") }
        let keyBefore = vm.modelCatalogKey

        store.invalidate()
        #expect(vm.modelCatalogKey != keyBefore)
        #expect(vm.modelCatalogKey.isCached == false)
        fake.resolvePending("models.list", with: [
            "models": [
                ["id": "sonnet4.5", "name": "Stale", "provider": "auggie"]
            ]
        ])
        await load.value
        #expect(vm.selectableModels == nil)
        #expect(vm.currentModelDisplayName == "sonnet4.5")

        fake.pendingMethods = []
        await vm.loadModelCatalogIfNeeded()
        #expect(vm.currentModelDisplayName == "Sonnet 4.5 (balanced)")
        #expect(fake.paramsForMethod("models.list").count == 2)
    }

    @Test func staleAgentGetFromBeforeReconnectNeverInstallsMetadata() async throws {
        let (vm, store, fake) = makeCatalogVM()
        fake.pendingMethods = ["agent.get"]
        let read = Task { await vm.fetchCurrentModel() }
        try await waitFor("agent.get") { fake.didCallMethod("agent.get") }

        store.invalidate()
        fake.resolvePending("agent.get", with: ["agent": ["model": "old-model", "provider": "grok"]])
        try await waitFor("re-read under the new generation") {
            fake.paramsForMethod("agent.get").count == 2
        }
        #expect(vm.currentModelId == nil)
        #expect(vm.currentProviderId == nil)
        #expect(vm.modelMetadataGeneration == nil)

        fake.resolvePending("agent.get", with: ["agent": ["model": "sonnet4.5", "provider": "auggie"]])
        await read.value
        #expect(vm.currentModelId == "sonnet4.5")
        #expect(vm.currentProviderId == "auggie")
        #expect(vm.modelMetadataGeneration == store.loadGeneration)
    }

    @Test func reconnectRereadsAgentMetadataThenReloadsCatalog() async {
        let (vm, store, fake) = makeCatalogVM()
        await vm.fetchCurrentModel()
        await vm.loadModelCatalogIfNeeded()
        #expect(vm.currentModelDisplayName == "Sonnet 4.5 (balanced)")
        #expect(fake.paramsForMethod("agent.get").count == 1)

        fake.responseMap["agent.get"] = ["agent": ["model": "opus", "provider": "auggie"]]
        fake.responseMap["models.list"] = [
            "models": [
                ["id": "opus", "name": "Opus", "provider": "auggie"]
            ]
        ]
        store.invalidate()
        #expect(vm.selectableModels == nil)

        await vm.loadModelCatalogIfNeeded()
        #expect(fake.paramsForMethod("agent.get").count == 2)
        #expect(fake.paramsForMethod("models.list").count == 2)
        #expect(vm.currentModelId == "opus")
        #expect(vm.currentModelDisplayName == "Opus")

        let requestsAfterReload = fake.requestLog.count
        await vm.loadModelCatalogIfNeeded()
        #expect(fake.requestLog.count == requestsAfterReload)
    }

    @Test func failedPostReconnectRereadDropsStaleMetadataAndSkipsCatalog() async {
        let (vm, store, fake) = makeCatalogVM()
        await vm.fetchCurrentModel()
        await vm.loadModelCatalogIfNeeded()
        #expect(vm.currentModelDisplayName == "Sonnet 4.5 (balanced)")

        fake.errorMap["agent.get"] = NSError(domain: "t", code: -1)
        store.invalidate()
        await vm.loadModelCatalogIfNeeded()
        #expect(fake.paramsForMethod("agent.get").count == 2)
        #expect(fake.paramsForMethod("models.list").count == 1)
        #expect(vm.currentModelId == nil)
        #expect(vm.currentProviderId == nil)
        #expect(vm.currentModelDisplayName == nil)
        #expect(store.models(for: "auggie") == nil)

        fake.errorMap["agent.get"] = nil
        fake.responseMap["agent.get"] = ["agent": ["model": "opus", "provider": "auggie"]]
        fake.responseMap["models.list"] = [
            "models": [
                ["id": "opus", "name": "Opus", "provider": "auggie"]
            ]
        ]
        await vm.loadModelCatalogIfNeeded()
        #expect(fake.paramsForMethod("agent.get").count == 3)
        #expect(fake.paramsForMethod("models.list").count == 2)
        #expect(vm.currentModelDisplayName == "Opus")
    }

    @Test func pickerSurfacesCatalogLoadFailureInsteadOfSpinning() async {
        let (vm, _, fake) = makeCatalogVM()
        await vm.fetchCurrentModel()
        fake.errorMap["models.list"] = NSError(domain: "t", code: -1)

        await vm.refreshSelectableModels()
        #expect(vm.selectableModels == nil)
        #expect(vm.modelCatalogLoadFailed)

        fake.errorMap["models.list"] = nil
        await vm.refreshSelectableModels()
        #expect(vm.selectableModels?.map(\.id) == ["sonnet4.5"])
        #expect(!vm.modelCatalogLoadFailed)
    }

    @Test func catalogLoadSupersededByReconnectDoesNotFlagFailure() async throws {
        let (vm, store, fake) = makeCatalogVM()
        await vm.fetchCurrentModel()
        fake.pendingMethods = ["models.list"]
        let load = Task { await vm.refreshSelectableModels() }
        try await waitFor("cold models.list") { fake.didCallMethod("models.list") }

        store.invalidate()
        fake.resolvePending("models.list", with: ["models": []])
        await load.value
        #expect(vm.selectableModels == nil)
        #expect(!vm.modelCatalogLoadFailed)
    }
}

extension ConversationViewModelTests {
    @Test func assistantWithoutProviderUsesHostDefaultCatalog() async {
        let (vm, _, fake) = makeCatalogVM()
        fake.responseMap["agent.get"] = ["agent": ["model": "default-model"]]
        fake.responseMap["settings.get"] = ["value": " codex "]
        fake.responseMap["agent.getModels"] = ["models": []]
        fake.responseMap["models.list"] = ["models": [["id": "default-model", "name": "Default Model", "provider": "codex"]]]

        await vm.refreshSelectableModels()

        #expect(vm.currentProviderId == nil)
        #expect(vm.modelProviderId == "codex")
        #expect(vm.currentModelDisplayName == "Default Model")
        #expect(vm.selectableModels?.map(\.id) == ["default-model"])
        #expect(fake.paramsForMethod("settings.get").first?["path"] as? String == "model.defaultProvider")
        #expect(fake.paramsForMethod("models.list").first?["providerId"] as? String == "codex")
        #expect(!fake.didCallMethod("agent.getModels"))
    }

    @Test(arguments: ["auggie", "codex@work"])
    func explicitProviderDoesNotUseHostDefault(provider: String) async {
        let (vm, _, fake) = makeCatalogVM()
        fake.responseMap["agent.get"] = ["agent": ["provider": provider]]
        fake.errorMap["settings.get"] = NSError(domain: "Unavailable", code: -1)

        await vm.refreshSelectableModels()

        #expect(fake.paramsForMethod("models.list").first?["providerId"] as? String == provider)
        #expect(!fake.didCallMethod("settings.get"))
        #expect(!vm.modelCatalogLoadFailed)
    }

    @Test(arguments: ["missing", "empty", "failed"])
    func unavailableInheritedProviderCanBeRetried(response: String) async {
        let (vm, _, fake) = makeCatalogVM()
        fake.responseMap["agent.get"] = ["agent": ["model": "sonnet4.5"]]
        fake.responseMap["settings.get"] = response == "empty" ? ["value": " "] : [:]
        if response == "failed" { fake.errorMap["settings.get"] = NSError(domain: "Unavailable", code: -1) }

        await vm.refreshSelectableModels()
        #expect(vm.selectableModels == nil)
        #expect(vm.modelCatalogLoadFailed)
        #expect(!fake.didCallMethod("models.list"))
        #expect(!fake.didCallMethod("agent.getModels"))

        fake.errorMap["settings.get"] = nil
        fake.responseMap["settings.get"] = ["value": "auggie"]
        await vm.refreshSelectableModels()
        #expect(vm.selectableModels?.map(\.id) == ["sonnet4.5"])
        #expect(!vm.modelCatalogLoadFailed)
    }

    @Test func reconnectDiscardsPendingInheritedProvider() async throws {
        let (vm, store, fake) = makeCatalogVM()
        fake.responseMap["agent.get"] = ["agent": ["model": "sonnet4.5"]]
        fake.pendingMethods = ["settings.get"]
        let load = Task { await vm.refreshSelectableModels() }
        try await waitUntil("default provider read") { fake.didCallMethod("settings.get") }

        store.invalidate()
        fake.resolvePending("settings.get", with: ["value": "codex"])
        await load.value
        #expect(vm.modelProviderId == nil)
        #expect(!fake.didCallMethod("models.list"))

        fake.pendingMethods = []
        fake.responseMap["settings.get"] = ["value": "auggie"]
        await vm.loadModelCatalogIfNeeded()
        #expect(vm.modelProviderId == "auggie")
        #expect(vm.currentModelDisplayName == "Sonnet 4.5 (balanced)")
    }

    @Test func inheritedProviderTracksDefaultSettingChanges() async {
        let (vm, _, fake) = makeCatalogVM()
        fake.responseMap["agent.get"] = ["agent": ["model": "sonnet4.5"]]
        fake.responseMap["settings.get"] = ["value": "auggie"]
        await vm.loadModelCatalogIfNeeded()
        let key = vm.modelCatalogKey

        fake.responseMap["settings.get"] = ["value": "codex"]
        fake.deliverEvent(method: "event", params: ["type": "settings:changed", "data": ["changes": [["path": "model.defaultProvider"]]]])
        await vm.loadModelCatalogIfNeeded()
        #expect(vm.modelCatalogKey != key)
        #expect(vm.modelProviderId == "codex")
        #expect(fake.paramsForMethod("models.list").last?["providerId"] as? String == "codex")
    }

    @Test func emptyProviderCatalogCanBeRefreshed() async {
        let (vm, _, fake) = makeCatalogVM()
        fake.responseMap["models.list"] = ["models": []]
        await vm.refreshSelectableModels()
        #expect(vm.selectableModels?.isEmpty == true)
        #expect(!vm.modelCatalogLoadFailed)

        fake.responseMap["models.list"] = ["models": [["id": "opus", "name": "Opus", "provider": "auggie"]]]
        await vm.refreshSelectableModels()
        #expect(vm.selectableModels?.map(\.id) == ["opus"])
    }
}

// swiftlint:enable identifier_name large_tuple
// swiftlint:enable no_magic_numbers
