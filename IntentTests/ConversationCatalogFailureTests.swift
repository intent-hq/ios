import Foundation
@testable import Intent
import Testing

extension ConversationStartupRPCTests {
    @Test func failedMetadataReleasesProviderUntilSuccessfulRetry() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop(); fixture.options.reset() }
        fixture.modelId = "model"
        fixture.providerId = "auggie"
        fixture.connection.responseMap["models.list"] = CreationOptionsStoreTests().modelReply("Known model")
        try await fixture.deliverInitialConnectionBeforeBinding()
        let viewModel = fixture.makeViewModel()
        await viewModel.load()
        await viewModel.loadModelCatalogIfNeeded()
        let connection = fixture.connection
        let failure = connection.checkpoint
        connection.errorMap["agent.get"] = URLError(.networkConnectionLost)
        fixture.options.invalidate()
        await viewModel.loadModelCatalogIfNeeded()
        #expect(viewModel.currentModelId == nil && viewModel.currentProviderId == nil)
        #expect(connection.traffic(since: failure).methodCounts == ["agent.get": 1])
        printCatalogLedger("failed-metadata-read", connection.traffic(since: failure))

        let event = connection.checkpoint
        CreationOptionsStoreTests().catalogEvent(connection, type: "settings:changed", paths: ["providers.paths.auggie"])
        try await expectNever("model refresh without a selected provider") { !connection.traffic(since: event).requests.isEmpty }
        printCatalogLedger("failed-metadata-settings", connection.traffic(since: event))
        try await reconnectAfterMetadataFailure(fixture, viewModel: viewModel, interested: false)
        #expect(viewModel.currentProviderId == nil)

        let retry = connection.checkpoint
        connection.errorMap["agent.get"] = nil
        await viewModel.loadModelCatalogIfNeeded()
        #expect(viewModel.currentProviderId == "auggie")
        #expect(viewModel.currentModelDisplayName == "Known model")
        #expect(connection.traffic(since: retry).methodCounts == ["agent.get": 1, "models.list": 1])
        #expect(viewModel.selectableModels == fixture.options.models(for: "auggie"))
        printCatalogLedger("failed-metadata-successful-retry", connection.traffic(since: retry))
        let selected = connection.checkpoint
        CreationOptionsStoreTests().catalogEvent(connection, type: "settings:changed", paths: ["providers.paths.auggie"])
        try await waitUntil("selected provider refresh resumes") { fixture.options.modelCatalog(for: "auggie").isFresh }
        #expect(connection.traffic(since: selected).methodCounts == ["models.list": 1])
        printCatalogLedger("failed-metadata-reselected-settings", connection.traffic(since: selected))
    }

    @Test func failedMetadataPreservesOtherConversationProviderInterest() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop(); fixture.options.reset() }
        fixture.modelId = "model"
        fixture.providerId = "auggie"
        fixture.connection.responseMap["models.list"] = CreationOptionsStoreTests().modelReply("Known model")
        try await fixture.deliverInitialConnectionBeforeBinding()
        let first = fixture.makeViewModel()
        let other = fixture.makeViewModel()
        await first.load()
        await first.loadModelCatalogIfNeeded()
        await other.load()
        await other.loadModelCatalogIfNeeded()
        let connection = fixture.connection
        connection.errorMap["agent.get"] = URLError(.networkConnectionLost)
        fixture.options.invalidate()
        // The other window still has a selected provider and can explicitly
        // refresh its models even while this window's metadata retry fails.
        await other.refreshSelectableModels()
        let cached = fixture.options.models(for: "auggie")
        await first.loadModelCatalogIfNeeded()
        #expect(first.currentProviderId == nil)
        #expect(other.currentProviderId == "auggie")
        #expect(fixture.options.models(for: "auggie") == cached)
        let event = connection.checkpoint
        CreationOptionsStoreTests().catalogEvent(connection, type: "settings:changed", paths: ["providers.paths.auggie"])
        try await waitUntil("other window's selected provider refreshed") { fixture.options.modelCatalog(for: "auggie").isFresh }
        #expect(connection.traffic(since: event).methodCounts == ["models.list": 1])
        printCatalogLedger("failed-metadata-other-window-settings", connection.traffic(since: event))
        try await reconnectAfterMetadataFailure(fixture, viewModel: first, interested: true)
        #expect(fixture.options.models(for: "auggie") == cached)

        other.teardownLiveStores()
        let released = connection.checkpoint
        CreationOptionsStoreTests().catalogEvent(connection, type: "settings:changed", paths: ["providers.paths.auggie"])
        try await expectNever("model refresh after the final selected window closes") {
            !connection.traffic(since: released).requests.isEmpty
        }
        #expect(fixture.options.models(for: "auggie") == cached)
        printCatalogLedger("failed-metadata-final-window-release", connection.traffic(since: released))
    }

    private func reconnectAfterMetadataFailure(
        _ fixture: ConversationStartupFixture, viewModel: ConversationViewModel, interested: Bool
    ) async throws {
        let connection = fixture.connection
        let checkpoint = connection.checkpoint
        connection.simulateDisconnect()
        connection.simulateConnect()
        try await waitUntil("reconnect bootstrap after metadata failure") {
            connection.traffic(since: checkpoint).calls("chat.subscribe").count == 1
                && connection.traffic(since: checkpoint).calls("agent.get").count == 1
                && connection.traffic().pendingCount == 0
                && (!interested || fixture.options.modelCatalog(for: "auggie").isFresh)
        }
        // Include the separately scheduled label task, including its metadata
        // retry after the reconnect bootstrap's detail request has failed.
        await viewModel.loadModelCatalogIfNeeded()
        let expectedModels = interested ? 1 : 0
        try await expectNever("model refresh without another selected window") {
            connection.traffic(since: checkpoint).calls("models.list").count > expectedModels
        }
        let traffic = connection.traffic(since: checkpoint)
        #expect(traffic.calls("models.list").count == expectedModels)
        #expect(traffic.calls("host.providerAuthStatus").isEmpty)
        #expect(traffic.calls("providers.catalog").isEmpty)
        printCatalogLedger(interested ? "failed-metadata-other-window-reconnect" : "failed-metadata-unselected-reconnect", traffic)
    }
}
