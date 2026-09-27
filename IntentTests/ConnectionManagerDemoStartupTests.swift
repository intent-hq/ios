import Foundation
@testable import Intent
import Testing

extension ConnectionManagerTests {
    @Test @MainActor func demoSessionPublishesReadinessAndResetsOnLogoff() async throws {
        let session = BackendSessionRegistry.makeLiveSession(backendID: nil)
        let manager = try #require(session.connection as? ConnectionManager)
        defer { session.teardown() }
        #expect(manager.globalSubscriptionState == .idle)
        session.connection.connectDemo(serveFixtures: true)
        let model = ConversationViewModel(
            agentId: DemoFixtures.longConversationAgentId,
            workspaceId: DemoFixtures.longConversationWorkspaceId,
            agentName: "Demo transcript",
            connection: session.connection,
            uploadService: session.attachmentUploadService,
            optionsStore: session.creationOptionsStore,
            agentDetails: session.agentDetails,
            conversations: session.conversations
        )
        defer { model.teardownLiveStores() }
        await model.load()
        #expect(manager.globalSubscriptionState == .subscribed)
        #expect(!model.messages.isEmpty && !model.isLoading)
        #expect(model.isEntryScrollReady)
        #expect(manager.socket == nil)
        model.teardownLiveStores()
        session.teardown()
        #expect(manager.connectionState == .disconnected)
        #expect(manager.globalSubscriptionState == .idle)
        session.connection.connectDemo(serveFixtures: true)
        await model.load()
        #expect(manager.globalSubscriptionState == .subscribed)
        #expect(model.isEntryScrollReady)
        // Demo loss/recovery drives this same publisher without a socket.
        manager.connectionState = .reconnecting(attempt: 1)
        #expect(manager.globalSubscriptionState == .idle)
        manager.connectionState = .connected
        #expect(manager.globalSubscriptionState == .subscribed)
    }

    @Test @MainActor func ordinaryConnectedStateDoesNotInventGlobalReadiness() {
        let manager = ConnectionManager()
        defer { manager.disconnect() }
        manager.connectionState = .connected
        #expect(manager.globalSubscriptionState == .idle)
        manager.globalSubscriptionState = .failed(attempts: 5, lastError: "No feed")
        manager.connectionState = .connected
        #expect(manager.globalSubscriptionState == .failed(attempts: 5, lastError: "No feed"))
    }
}
