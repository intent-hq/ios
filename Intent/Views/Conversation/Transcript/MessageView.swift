import SwiftUI

struct MessageView: View {
    let message: ConversationMessage
    let workspaceId: String
    var onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)?
    var onNavigateToAgent: ((_ agentId: String, _ workspaceId: String, _ agentName: String) -> Void)?
    /// Block ids of this message with a slim-projection hydration fetch in
    /// flight (agent.getMessageBlock, PROTOCOL §5.5).
    var hydratingBlockIds: Set<String> = []
    /// Fetch the full body of a slim-truncated block of this message by id.
    var onHydrateBlock: ((_ blockId: String) -> Void)?
    /// Agent-to-agent rows render as a collapsed disclosure card; the body
    /// is hidden until the header is tapped (FE parity: ChatMessage.svelte
    /// `isAgentMessageExpanded`, collapsed by default).
    @State private var isAgentMessageExpanded = false

    private var isUser: Bool { message.role == .user }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            messageContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var messageContent: some View {
        if let dismissedNotice = message.questionsDismissedNotice {
            QuestionsDismissedNoticeView(notice: dismissedNotice)
        } else if let modelChange = message.modelChangeNotice {
            ModelChangeNoticeView(notice: modelChange, fallbackText: message.joinedTextContent)
        } else if isUser, let eventWake = message.eventWakeAttribution {
            EventWakeBannerView(attribution: eventWake)
        } else if isUser {
            UserMessageView(
                message: message,
                workspaceId: workspaceId,
                onNavigateToAgent: onNavigateToAgent,
                isAgentMessageExpanded: $isAgentMessageExpanded
            )
        } else if message.role == .assistant {
            AssistantMessageView(
                message: message,
                workspaceId: workspaceId,
                onNavigateToNote: onNavigateToNote,
                hydratingBlockIds: hydratingBlockIds,
                onHydrateBlock: onHydrateBlock
            )
        } else if message.role == .error {
            ErrorMessageView(message: message)
        } else if message.role == .system {
            systemMessage
        }
    }

    @ViewBuilder
    private var systemMessage: some View {
        if let notice = message.attentionNotice {
            AttentionNoticeView(notice: notice)
        } else {
            SystemNoticeBannerView(message: message.joinedTextContent)
        }
    }
}
