import Foundation
@testable import Intent
import Observation
import Synchronization
import Testing
import UIKit

// Tests share the PersistenceManager draft key "test-ws"/"test-agent".
@Suite(.serialized)
@MainActor
struct ConversationViewModelTests {
    // MARK: - Helpers

    func makeVM(workspaceId: String = "test-ws") -> ConversationViewModel {
        ConversationViewModel(
            agentId: "test-agent",
            workspaceId: workspaceId,
            agentName: "Test",
            connection: ConnectionManager.shared,
            uploadService: .shared,
            optionsStore: CreationOptionsStore()
        )
    }

    func textMessage(
        role: MessageRole,
        text: String,
        id: String = UUID().uuidString,
        metadata: [String: AnyCodable] = [:]
    ) -> ConversationMessage {
        ConversationMessage(
            id: id,
            role: role,
            contentBlocks: [ContentBlock(type: .text, text: text)],
            metadata: metadata
        )
    }

    func questionResourceBlock(
        attachmentId: String = "tar-0123456789ab",
        question: String = "Which auth method?"
    ) -> ContentBlock {
        let json = """
        {"attachmentId": "\(attachmentId)", "header": "Auth", \
        "question": "\(question)", \
        "options": [{"label": "OAuth"}, {"label": "API key"}]}
        """
        return ContentBlock(
            type: .resource,
            resource: ResourceContents(
                uri: "intent-question://q",
                mimeType: Question.resourceMimeType,
                text: json
            )
        )
    }

    func questionMessage(
        id: String = "a1",
        extraBlocks: [ContentBlock] = []
    ) -> ConversationMessage {
        ConversationMessage(
            id: id,
            role: .assistant,
            contentBlocks: [questionResourceBlock()] + extraBlocks
        )
    }

    // MARK: - filteredMessages

    @Test func filteredMessagesKeepsWorkspaceEvents() {
        // Event wakes render as a banner (or fall back to the user bubble
        // on legacy text-only rows) — they are no longer hidden.
        let viewModel = makeVM()
        viewModel.store.messages = [
            textMessage(role: .user, text: "[WORKSPACE EVENTS] something happened")
        ]
        #expect(viewModel.filteredMessages.count == 1)
    }

    @Test func filteredMessagesKeepsTaskWake() {
        let viewModel = makeVM()
        viewModel.store.messages = [
            textMessage(role: .user, text: "[TASK WAKE] waking up")
        ]
        #expect(viewModel.filteredMessages.count == 1)
    }

    @Test func filteredMessagesKeepsAgentMessage() {
        // A2A sends are no longer hidden — MessageView renders them with a
        // sender attribution header instead.
        let viewModel = makeVM()
        viewModel.store.messages = [
            textMessage(role: .user, text: "[AGENT MESSAGE] from another agent")
        ]
        #expect(viewModel.filteredMessages.count == 1)
    }

    @Test func filteredMessagesKeepsEventNotificationMetadata() {
        let viewModel = makeVM()
        viewModel.store.messages = [
            textMessage(
                role: .user,
                text: "event data",
                metadata: ["type": AnyCodable("event_notification")]
            )
        ]
        #expect(viewModel.filteredMessages.count == 1)
    }

    @Test func filteredMessagesHandlesEmptyList() {
        let viewModel = makeVM()
        viewModel.store.messages = []
        #expect(viewModel.filteredMessages.isEmpty)
    }

    @Test func filteredMessagesMixedKeepsCorrectOnes() {
        let viewModel = makeVM()
        viewModel.store.messages = [
            textMessage(role: .user, text: "Hello"),
            textMessage(role: .assistant, text: "Hi"),
            textMessage(role: .user, text: "[WORKSPACE EVENTS] x"),
            textMessage(role: .user, text: "[AGENT MESSAGE] z"),
            textMessage(role: .assistant, text: "Done")
        ]
        #expect(viewModel.filteredMessages.count == 5)
    }

    @Test func transcriptMembershipTracksMutationsAndReset() {
        let viewModel = makeVM()
        viewModel.store.messages = [textMessage(role: .assistant, text: "First", id: "first")]
        #expect(viewModel.filteredMessageIDs == ["first"])
        viewModel.store.messages[0].contentBlocks = [ContentBlock(type: .text, text: "Updated")]
        #expect(viewModel.filteredMessageIDs == ["first"])
        viewModel.store.messages.insert(textMessage(role: .user, text: "Older", id: "older"), at: 0)
        #expect(viewModel.filteredMessageIDs == ["older", "first"])
        viewModel.store.messages.append(textMessage(role: .assistant, text: "Live", id: "live"))
        #expect(viewModel.filteredMessageIDs == ["older", "first", "live"])
        let retainedIDs = viewModel.filteredMessageIDs
        viewModel.store.messages[1].contentBlocks = [ContentBlock(type: .text, text: "Another token")]
        #expect(viewModel.filteredMessageIDs == retainedIDs)
        viewModel.store.messages[1] = textMessage(role: .assistant, text: "Replacement", id: "replacement")
        #expect(viewModel.filteredMessageIDs == ["older", "replacement", "live"])
        #expect(retainedIDs == ["older", "first", "live"])
        viewModel.store.messages.removeFirst()
        #expect(viewModel.filteredMessageIDs == ["replacement", "live"])
        viewModel.store.reset()
        #expect(viewModel.filteredMessageIDs.isEmpty)
    }

    @Test func cachedTranscriptMembershipRemainsObservableAcrossStoreChanges() {
        let viewModel = makeVM()
        viewModel.store.messages = [textMessage(role: .user, text: "Old", id: "old")]
        #expect(viewModel.filteredMessageIDs == ["old"])
        let changes = Mutex(0)
        withObservationTracking { _ = viewModel.filteredMessageIDs } onChange: {
            changes.withLock { $0 += 1 }
        }
        viewModel.store.messages[0] = textMessage(role: .user, text: "New", id: "new")
        #expect(changes.withLock { $0 } == 1)
        #expect(viewModel.filteredMessageIDs == ["new"])
        withObservationTracking { _ = viewModel.filteredMessageIDs } onChange: {
            changes.withLock { $0 += 1 }
        }
        let replacement = ConversationStore()
        replacement.messages = [textMessage(role: .user, text: "Other conversation", id: "other")]
        viewModel.store = replacement
        #expect(changes.withLock { $0 } == 2)
        #expect(viewModel.filteredMessageIDs == ["other"])
    }

    // MARK: - queuedMessages display filter

    func queuedEntry(
        id: String,
        content: String = "c",
        metadata: [String: AnyCodable] = [:]
    ) -> QueuedMessage {
        QueuedMessage(
            id: id,
            content: content,
            queuedAt: "2025-01-01T00:00:00Z",
            position: 0,
            messageMetadata: metadata
        )
    }

    @Test func queuedMessagesHidesNonUserEntries() {
        let viewModel = makeVM()
        viewModel.store.queuedMessages = [
            queuedEntry(id: "q-user"),
            // Malformed agent message (no fromAgentId): typed metadata → hidden.
            queuedEntry(id: "q-agent-bad", metadata: ["type": AnyCodable("agent_message")]),
            queuedEntry(id: "q-system", metadata: ["source": AnyCodable("system")]),
            queuedEntry(id: "q-benign", metadata: ["userAppMessageId": AnyCodable("uam-1")])
        ]
        #expect(viewModel.queuedMessages.map(\.id) == ["q-user", "q-benign"])
        // The store keeps the full queue (flush behavior untouched).
        #expect(viewModel.store.queuedMessages.count == 4)
    }

    @Test func queuedMessagesHidesAgentMessageEntries() {
        // Agent-to-agent sends are daemon-originated: hidden from the section.
        let viewModel = makeVM()
        viewModel.store.queuedMessages = [
            queuedEntry(id: "q-agent", metadata: [
                "type": AnyCodable("agent_message"),
                "fromAgentId": AnyCodable("agent-2"),
                "fromAgentName": AnyCodable("Verifier")
            ])
        ]
        #expect(viewModel.queuedMessages.isEmpty)
    }

    @Test func queuedMessagesHidesEventNotificationEntries() {
        // Metadata-typed event-notification wakes are hidden; legacy
        // content-prefix entries without metadata fail open as user-authored
        // (`isUserMessage` rules unchanged).
        let viewModel = makeVM()
        viewModel.store.queuedMessages = [
            queuedEntry(id: "q-event", metadata: ["type": AnyCodable("event_notification")]),
            queuedEntry(id: "q-event-legacy", content: "[WORKSPACE EVENTS] 1 event")
        ]
        #expect(viewModel.queuedMessages.map(\.id) == ["q-event-legacy"])
    }

    @Test func queuedMessagesEmptyWhenOnlyNonUserEntries() {
        let viewModel = makeVM()
        viewModel.store.queuedMessages = [
            queuedEntry(id: "q-agent", metadata: ["fromAgentId": AnyCodable("agent-2")])
        ]
        #expect(viewModel.queuedMessages.isEmpty)
    }

    @Test func queuedMessagesHidesWakeEntries() {
        // Hook and PR-monitor wakes (PROTOCOL §5.40 / §5.42) are
        // daemon-originated: hidden from the section.
        let viewModel = makeVM()
        viewModel.store.queuedMessages = [
            queuedEntry(id: "q-hook", metadata: [
                "type": AnyCodable("hook_wake"),
                "hookId": AnyCodable("h-1"),
                "hookName": AnyCodable("CI watcher"),
                "reason": AnyCodable("dispatched")
            ]),
            queuedEntry(id: "q-pr", metadata: [
                "type": AnyCodable("pr_monitor_wake"),
                "monitorId": AnyCodable("m-1"),
                "repo": AnyCodable("intent-hq/intentd"),
                "prNumber": AnyCodable(7)
            ]),
            // Malformed PR wake (no repo): still a typed entry → hidden.
            queuedEntry(id: "q-pr-bad", metadata: ["type": AnyCodable("pr_monitor_wake")])
        ]
        #expect(viewModel.queuedMessages.isEmpty)
    }

    // MARK: - suggestedPrompts

    @Test func suggestedPromptsParsesSinglePrompt() {
        let viewModel = makeVM()
        viewModel.store.messages = [
            textMessage(
                role: .assistant,
                text: "Here you go\n<!-- suggested-prompts\nRun the tests\n-->"
            )
        ]
        #expect(viewModel.suggestedPrompts == ["Run the tests"])
    }

    @Test func suggestedPromptsMultiplePrompts() {
        let viewModel = makeVM()
        viewModel.store.messages = [
            textMessage(
                role: .assistant,
                text: "Done!\n<!-- suggested-prompts\nPrompt 1\nPrompt 2\nPrompt 3\n-->"
            )
        ]
        #expect(viewModel.suggestedPrompts == ["Prompt 1", "Prompt 2", "Prompt 3"])
    }
}

extension ConversationViewModelTests {
    @Test func suggestedPromptsEmptyWhenLastIsUser() {
        let viewModel = makeVM()
        viewModel.store.messages = [
            textMessage(role: .assistant, text: "<!-- suggested-prompts\nA\n-->"),
            textMessage(role: .user, text: "thanks")
        ]
        #expect(viewModel.suggestedPrompts.isEmpty)
    }

    @Test func suggestedPromptsEmptyWhenNoComment() {
        let viewModel = makeVM()
        viewModel.store.messages = [
            textMessage(role: .assistant, text: "Just a normal message")
        ]
        #expect(viewModel.suggestedPrompts.isEmpty)
    }

    @Test func suggestedPromptsTrimsWhitespace() {
        let viewModel = makeVM()
        viewModel.store.messages = [
            textMessage(
                role: .assistant,
                text: "<!-- suggested-prompts\n  Spaced prompt  \n-->"
            )
        ]
        #expect(viewModel.suggestedPrompts == ["Spaced prompt"])
    }

    @Test func suggestedPromptsIgnoresEmptyLines() {
        let viewModel = makeVM()
        viewModel.store.messages = [
            textMessage(
                role: .assistant,
                text: "<!-- suggested-prompts\nA\n\n\nB\n-->"
            )
        ]
        #expect(viewModel.suggestedPrompts == ["A", "B"])
    }

    @Test func suggestedPromptsSpanningTwoTextBlocks() {
        // Text blocks join with the empty separator (desktop parity), so a
        // block boundary reassembles the original stream — even mid-line.
        let viewModel = makeVM()
        viewModel.store.messages = [
            ConversationMessage(
                id: UUID().uuidString,
                role: .assistant,
                contentBlocks: [
                    ContentBlock(type: .text, text: "Done!\n<!-- suggested-prompts\nRun the te"),
                    ContentBlock(type: .text, text: "sts\n-->")
                ]
            )
        ]
        #expect(viewModel.suggestedPrompts == ["Run the tests"])
    }

    @Test func suggestedPromptsEmptyWhenNoMessages() {
        let viewModel = makeVM()
        #expect(viewModel.suggestedPrompts.isEmpty)
    }

    #if DEBUG
    @Test func repeatedImagePromptOpenerUpdatesWhenStreamCloses() throws {
        let viewModel = makeVM()
        let partial = "![Preview](workspace-asset://ws/image.png)\n<!-- suggested-prompts\n<!-- suggested-"
        let block = ContentBlock(type: .text, text: partial)
        var message = ConversationMessage(id: "image-response", role: .assistant, contentBlocks: [block])
        message.isStreaming = true
        viewModel.store.messages = [message]
        #expect(viewModel.suggestedPrompts.isEmpty)
        let before = SuggestedPrompts.parse(contentBlocks: message.contentBlocks).contentBlocks
        #expect(before.first?.resolvedText == partial)

        message.contentBlocks.append(ContentBlock(
            type: .text,
            text: "prompts\nShow the recording screen.\nShow the mobile layout.\n-->"
        ))
        message.isStreaming = false
        viewModel.store.messages = [message]
        #expect(viewModel.suggestedPrompts == DemoFixtures.inlineImageSuggestedPrompts)
        let after = SuggestedPrompts.parse(contentBlocks: message.contentBlocks).contentBlocks
        let oldBlock = try #require(before.first)
        let newBlock = try #require(after.first)
        #expect(oldBlock.id == newBlock.id)
        #expect(newBlock.resolvedText == "![Preview](workspace-asset://ws/image.png)\n")
        #expect(ContentBlockBody(block: oldBlock, toolResult: nil, workspaceId: "ws")
            != ContentBlockBody(block: newBlock, toolResult: nil, workspaceId: "ws"))

        viewModel.store.messages = []
        viewModel.store.messages = [message]
        #expect(viewModel.suggestedPrompts == DemoFixtures.inlineImageSuggestedPrompts)
    }
    #endif
}
