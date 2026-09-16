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
}
