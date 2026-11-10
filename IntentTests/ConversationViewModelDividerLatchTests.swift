import Foundation
@testable import Intent
import Testing

@MainActor
struct ConversationViewModelDividerLatchTests {
    private func makeViewModel() -> ConversationViewModel {
        ConversationViewModel(
            agentId: "test-agent",
            workspaceId: "test-ws",
            agentName: "Test",
            connection: ConnectionManager.shared,
            uploadService: .shared,
            optionsStore: CreationOptionsStore()
        )
    }

    private func message(_ id: String, role: MessageRole = .assistant) -> ConversationMessage {
        ConversationMessage(
            id: id,
            role: role,
            contentBlocks: [ContentBlock(type: .text, text: "text for \(id)")]
        )
    }

    @Test func latchesAnchorOnEntryAndExposesIt() {
        let viewModel = makeViewModel()
        viewModel.store.messages = ["m1", "m2", "m3", "m4"].map { message($0) }
        viewModel.store.lastSeenMessageId = "m2"
        viewModel.latchNewMessagesDividerAnchorIfNeeded()
        #expect(viewModel.newMessagesDividerAnchorId == "m2")
    }

    @Test func markerConvergenceAfterEntryDoesNotMoveDivider() {
        let viewModel = makeViewModel()
        viewModel.store.messages = ["m1", "m2", "m3", "m4"].map { message($0) }
        viewModel.store.lastSeenMessageId = "m2"
        viewModel.latchNewMessagesDividerAnchorIfNeeded()
        viewModel.store.lastSeenMessageId = "m4"
        #expect(viewModel.newMessagesDividerAnchorId == "m2")
        viewModel.store.messages.append(message("m5"))
        #expect(viewModel.newMessagesDividerAnchorId == "m2")
        viewModel.latchNewMessagesDividerAnchorIfNeeded()
        #expect(viewModel.newMessagesDividerAnchorId == "m2")
    }

    @Test func nilLatchMeansNoDividerAllSession() {
        let viewModel = makeViewModel()
        viewModel.store.messages = ["m1", "m2"].map { message($0) }
        viewModel.store.lastSeenMessageId = nil
        viewModel.latchNewMessagesDividerAnchorIfNeeded()
        #expect(viewModel.newMessagesDividerAnchorId == nil)
        viewModel.store.lastSeenMessageId = "m1"
        viewModel.latchNewMessagesDividerAnchorIfNeeded()
        #expect(viewModel.newMessagesDividerAnchorId == nil)
    }

    @Test func markerAtNewestLatchesNil() {
        let viewModel = makeViewModel()
        viewModel.store.messages = ["m1", "m2"].map { message($0) }
        viewModel.store.lastSeenMessageId = "m2"
        viewModel.latchNewMessagesDividerAnchorIfNeeded()
        #expect(viewModel.newMessagesDividerAnchorId == nil)
    }

    @Test func anchorTruncatedAwayHidesWithoutRederiving() {
        let viewModel = makeViewModel()
        viewModel.store.messages = ["m1", "m2", "m3", "m4"].map { message($0) }
        viewModel.store.lastSeenMessageId = "m2"
        viewModel.latchNewMessagesDividerAnchorIfNeeded()
        #expect(viewModel.newMessagesDividerAnchorId == "m2")
        viewModel.store.messages = ["m1", "m3", "m4"].map { message($0) }
        viewModel.store.lastSeenMessageId = "m1"
        #expect(viewModel.newMessagesDividerAnchorId == nil)
    }

    @Test func retainedReappearanceKeepsItsDividerWhileMetadataRevalidates() async throws {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        fixture.connection.pendingMethods = ["agent.get"]
        let opening = Task { await model.load() }
        defer { opening.cancel(); fixture.stop() }
        try await fixture.connection.waitForPendingRequests("agent.get")
        try await waitUntil("early transcript") { model.store.liveTranscript.chatSeeded }
        model.store.messages.append(message("unread"))
        fixture.connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        await opening.value
        #expect(model.newMessagesDividerAnchorId == ConversationStartupFixture.messageId)
        model.teardownLiveStores()
        let returning = Task { await model.load() }
        defer { returning.cancel() }
        try await fixture.connection.waitForPendingRequests("agent.get")
        #expect(!model.store.metadataReadyForEntry)
        #expect(model.isEntryScrollReady, "same-view authority was already established on first entry")
        #expect(model.newMessagesDividerAnchorId == ConversationStartupFixture.messageId,
                "removing the retained divider shifts every visible row below it")
        var detail = fixture.agent(ConversationStartupFixture.parentId)
        detail["metadata"] = ["lastSeenMessageId": "unread"]
        fixture.connection.resolvePending("agent.get", with: ["agent": detail])
        await returning.value
        #expect(model.newMessagesDividerAnchorId == ConversationStartupFixture.messageId)
        #expect(fixture.connection.paramsForMethod("agent.get").count == 2)
        #expect(fixture.connection.paramsForMethod("chat.subscribe").count == 2)
    }

    @Test func onlyAChangedStoreClearsTheEntryAuthorityLatch() {
        let model = makeViewModel()
        model.store.messages = [message("seen"), message("unread")]
        model.store.lastSeenMessageId = "seen"
        model.latchNewMessagesDividerAnchorIfNeeded()
        let sameStore = model.store
        model.store = sameStore
        #expect(model.newMessagesDividerAnchorId == "seen")
        let otherBackend = FakeConnectionManager()
        model.store = ConversationStore(connectionManager: otherBackend)
        #expect(!model.isEntryScrollReady)
        #expect(model.newMessagesDividerLatch == .unlatched)
        model.store.messages = [message("other-seen"), message("other-unread")]
        model.store.lastSeenMessageId = "other-seen"
        model.latchNewMessagesDividerAnchorIfNeeded()
        #expect(model.newMessagesDividerAnchorId == "other-seen")
    }

    @Test func latchTakesOneAnchorAndOnlyAStoreChangeResetsIt() {
        let model = makeViewModel()
        model.store.messages = ["m1", "m2"].map { message($0) }
        model.store.lastSeenMessageId = "m2"
        #expect(model.newMessagesDividerLatch == .unlatched)
        #expect(!model.isEntryScrollReady)
        model.latchNewMessagesDividerAnchorIfNeeded()
        #expect(model.newMessagesDividerLatch == .latched(anchorId: nil), "a nil anchor still latches entry")
        #expect(model.isEntryScrollReady)
        model.store.messages.append(message("m3"))
        model.latchNewMessagesDividerAnchorIfNeeded()
        #expect(model.newMessagesDividerLatch == .latched(anchorId: nil), "a second entry signal never re-derives")
        model.store = ConversationStore(connectionManager: FakeConnectionManager())
        #expect(model.newMessagesDividerLatch == .unlatched)
        #expect(!model.isEntryScrollReady)
        model.store.messages = ["n1", "n2"].map { message($0) }
        model.store.lastSeenMessageId = "n1"
        model.latchNewMessagesDividerAnchorIfNeeded()
        #expect(model.newMessagesDividerLatch == .latched(anchorId: "n1"))
        #expect(model.newMessagesDividerAnchorId == "n1")
    }
}
