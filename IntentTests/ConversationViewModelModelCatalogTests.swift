import Foundation
@testable import Intent
import Testing

// These extracted tests retain the parent suite's compact fixture vocabulary.
// swiftlint:disable identifier_name large_tuple
// Keep the existing polling attempt count and interval explicit without changing the test budget.
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

    // MARK: - Model display name (conversation menu)

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

    /// Bounded poll; records a failure on timeout so a missed update cannot
    /// pass silently.
    private func waitFor(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for \(description)")
    }

    /// The menu label reads the session's shared per-provider cache once the
    /// provider is known, so a warm cache renders the name with no request.
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

    /// A reconnect during the cold catalog load never flips `isCached`, so
    /// the task identity must move on the generation alone: the stale
    /// completion is dropped (nil before, nil after) and the next task run
    /// starts a fresh flight.
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

    /// An `agent.get` response from before a reconnect is stale: it never
    /// installs its model/provider; the read repeats under the new
    /// generation and only that answer lands.
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

    /// After a reconnect the catalog task re-reads the agent's metadata
    /// (the model may have changed while offline) before reloading the
    /// catalog, so the label shows the authoritative post-reconnect model.
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

    /// A failed post-reconnect re-read leaves no authoritative metadata:
    /// the pre-reconnect model/provider are dropped (placeholder label, not
    /// a stale one) and no catalog is loaded for them; the next task run
    /// re-reads, and only a fresh `agent.get` restores the label.
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

    /// A failed provider-scoped `models.list` leaves the catalog nil: the
    /// picker must surface a retryable failure state instead of spinning
    /// forever, and a successful retry clears it.
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

    /// A catalog load superseded by a reconnect is neither a success nor a
    /// failure: the flag stays clear and the generation-keyed task reloads.
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

// swiftlint:enable identifier_name large_tuple
// swiftlint:enable no_magic_numbers
