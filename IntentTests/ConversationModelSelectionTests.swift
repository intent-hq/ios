import Foundation
@testable import Intent
import Testing

@MainActor
struct ConversationModelSelectionTests {
    private struct Fixture {
        let selection: ConversationModelSelection
        let viewModel: ConversationViewModel
        let fake: FakeConnectionManager
    }

    private func fixture() async -> Fixture {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.get"] = ["agent": ["provider": "codex", "model": "shared-model", "reasoningEffort": "high"]]
        fake.responseMap["providers.catalog"] = [
            "providers": [
                ["id": "codex", "visible": true, "canBeDisabled": true],
                ["id": "claude-code", "visible": true, "canBeDisabled": true]
            ]
        ]
        fake.responseMap["settings.get"] = ["path": "providers.enabled", "value": ["codex": true, "claude-code": true]]
        fake.responseMap["host.providerAuthStatus"] = ["providers": [["id": "codex", "authenticated": true], ["id": "claude-code", "authenticated": true]]]
        fake.responseMap["models.list"] = ["models": [["id": "shared-model", "name": "Shared Model", "effortLevels": ["low", "high"]]]]
        fake.responseMap["agent.setModel"] = ["success": true]
        fake.responseMap["agent.update"] = ["success": true]
        let viewModel = ConversationViewModel(
            agentId: "test-agent",
            workspaceId: "test-workspace",
            agentName: "Test",
            connection: fake,
            uploadService: AttachmentUploadService(connection: fake),
            optionsStore: CreationOptionsStore(connectionManager: fake)
        )
        let selection = ConversationModelSelection(viewModel: viewModel)
        await selection.load()
        await selection.loadModels()
        return Fixture(selection: selection, viewModel: viewModel, fake: fake)
    }

    @Test func openingKeepsCurrentSettingsWithoutWriting() async {
        let fixture = await fixture()
        #expect(fixture.selection.providerID == "codex")
        #expect(fixture.selection.modelID == "shared-model")
        #expect(fixture.selection.reasoningEffort == "high")
        #expect(!fixture.selection.canSave)
        #expect(!fixture.fake.didCallMethod("agent.setModel"))
        #expect(!fixture.fake.didCallMethod("agent.update"))
    }

    @Test func providerChangeWaitsForSaveAndConfirmationAndClearsReasoning() async throws {
        let fixture = await fixture()
        fixture.viewModel.messageText = "Keep my draft"
        fixture.selection.selectProvider(ProviderInfo(id: "claude-code"))
        await fixture.selection.loadModels()
        #expect(fixture.selection.modelID == nil)
        #expect(fixture.selection.reasoningEffort == nil)
        #expect(!fixture.fake.didCallMethod("agent.setModel"))
        fixture.fake.pendingMethods = ["agent.setModel"]
        let save = Task { await fixture.selection.save() }
        try await waitUntil("model save") { fixture.fake.didCallMethod("agent.setModel") }
        #expect(fixture.viewModel.currentProviderId == "codex")
        #expect(fixture.viewModel.currentModelId == "shared-model")
        #expect(await fixture.selection.save() == false)
        fixture.fake.resolvePending("agent.setModel", with: ["success": true])
        #expect(await save.value)
        #expect(fixture.viewModel.currentProviderId == "claude-code")
        #expect(fixture.viewModel.currentModelId == "default")
        #expect(fixture.viewModel.currentReasoningEffort == nil)
        #expect(fixture.viewModel.messageText == "Keep my draft")
        let params = try #require(fixture.fake.paramsForMethod("agent.setModel").first)
        #expect(params["providerId"] as? String == "claude-code")
        #expect(params["modelId"] as? String == "default")
        let changes = try #require(fixture.fake.paramsForMethod("agent.update").first?["changes"] as? [String: Any])
        #expect(changes["reasoningEffort"] is NSNull)
    }

    @Test func sameModelIDOnDifferentProviderStillSwitchesProvider() async {
        let fixture = await fixture()
        fixture.selection.selectProvider(ProviderInfo(id: "claude-code"))
        await fixture.selection.loadModels()
        fixture.selection.selectModel(fixture.selection.models.first)
        fixture.selection.reasoningEffort = "low"
        #expect(await fixture.selection.save())
        #expect(fixture.fake.paramsForMethod("agent.setModel").first?["providerId"] as? String == "claude-code")
        #expect(fixture.viewModel.currentModelId == "shared-model")
        #expect(fixture.viewModel.currentReasoningEffort == "low")
    }

    @Test func failedProviderChangeKeepsDraftSettingsForRetry() async {
        let fixture = await fixture()
        fixture.selection.selectProvider(ProviderInfo(id: "claude-code"))
        await fixture.selection.loadModels()
        fixture.fake.errorMap["agent.setModel"] = CocoaError(.fileReadUnknown)
        #expect(await fixture.selection.save() == false)
        #expect(fixture.viewModel.currentProviderId == "codex")
        #expect(fixture.selection.providerID == "claude-code")
        #expect(fixture.selection.errorMessage != nil)
        #expect(!fixture.fake.didCallMethod("agent.update"))
        fixture.fake.errorMap["agent.setModel"] = nil
        #expect(await fixture.selection.save())
    }

    @Test func failedReasoningSaveRetriesOnlyTheUnsavedChoice() async {
        let fixture = await fixture()
        fixture.selection.selectProvider(ProviderInfo(id: "claude-code"))
        await fixture.selection.loadModels()
        fixture.fake.errorMap["agent.update"] = CocoaError(.fileReadUnknown)
        #expect(await fixture.selection.save() == false)
        #expect(fixture.viewModel.currentProviderId == "claude-code")
        #expect(fixture.viewModel.currentReasoningEffort == "high")
        #expect(fixture.selection.errorMessage?.contains("Provider and model were saved") == true)
        #expect(fixture.selection.canSave)
        fixture.fake.errorMap["agent.update"] = nil
        #expect(await fixture.selection.save())
        #expect(fixture.fake.paramsForMethod("agent.setModel").count == 1)
        #expect(fixture.fake.paramsForMethod("agent.update").count == 2)
    }

    @Test func disabledCurrentProviderCanChangeModelButNewSignedOutProviderCannotBeSelected() async {
        let fixture = await fixture()
        fixture.fake.responseMap["settings.get"] = ["path": "providers.enabled", "value": ["codex": false, "claude-code": true]]
        fixture.fake.responseMap["host.providerAuthStatus"] = ["providers": [["id": "claude-code", "authenticated": false]]]
        await fixture.selection.load()
        #expect(fixture.selection.provider?.isSelectable == true)
        fixture.selection.selectProvider(ProviderInfo(id: "claude-code", authenticated: .signedOut))
        #expect(fixture.selection.providerID == "codex")
        fixture.selection.selectModel(nil)
        #expect(fixture.selection.canSave)
    }

    @Test func providerLoadFailureKeepsTheDraftButBlocksSaveUntilRetry() async {
        let fixture = await fixture()
        fixture.selection.selectProvider(ProviderInfo(id: "claude-code"))
        await fixture.selection.loadModels()
        fixture.fake.errorMap["providers.catalog"] = CocoaError(.fileReadUnknown)
        await fixture.selection.load()
        #expect(fixture.selection.providerID == "claude-code")
        #expect(!fixture.selection.canSave)
        fixture.fake.errorMap["providers.catalog"] = nil
        await fixture.selection.load()
        #expect(fixture.selection.canSave)
    }

    @Test func reconnectDuringSaveDoesNotPublishOldConfirmationOrWriteReasoning() async throws {
        let fixture = await fixture()
        fixture.selection.selectProvider(ProviderInfo(id: "claude-code"))
        await fixture.selection.loadModels()
        fixture.fake.pendingMethods = ["agent.setModel"]
        let save = Task { await fixture.selection.save() }
        try await waitUntil("model save") { fixture.fake.didCallMethod("agent.setModel") }
        fixture.selection.options.invalidate()
        fixture.fake.resolvePending("agent.setModel", with: ["success": true])
        #expect(await save.value == false)
        #expect(fixture.viewModel.currentProviderId == "codex")
        #expect(!fixture.fake.didCallMethod("agent.update"))
    }

    @Test func lateCatalogFromPreviousProviderDoesNotReplaceSelection() async throws {
        let fixture = await fixture()
        fixture.fake.requestLog = []
        fixture.fake.pendingMethods = ["models.list"]
        let oldLoad = Task { await fixture.selection.loadModels() }
        try await waitUntil("old provider catalog") { fixture.fake.didCallMethod("models.list") }
        fixture.selection.selectProvider(ProviderInfo(id: "claude-code"))
        let newLoad = Task { await fixture.selection.loadModels() }
        try await waitUntil("new provider catalog") { fixture.fake.paramsForMethod("models.list").count == 2 }
        fixture.fake.resolvePending("models.list", with: ["models": [["id": "old-model", "name": "Old Model"]]])
        await oldLoad.value
        #expect(fixture.selection.providerID == "claude-code")
        #expect(fixture.selection.isLoadingModels)
        fixture.fake.resolvePending("models.list", with: ["models": [["id": "new-model", "name": "New Model"]]])
        await newLoad.value
        #expect(fixture.selection.models.map(\.id) == ["new-model"])
    }
}
