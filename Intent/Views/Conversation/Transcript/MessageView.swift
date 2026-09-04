import SwiftUI

struct MessageView: View {
    let message: ConversationMessage
    let workspaceId: String
    var onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)? = nil
    var onNavigateToAgent: ((_ agentId: String, _ workspaceId: String, _ agentName: String) -> Void)? = nil
    /// Block ids of this message with a slim-projection hydration fetch in
    /// flight (agent.getMessageBlock, PROTOCOL §5.5).
    var hydratingBlockIds: Set<String> = []
    /// Fetch the full body of a slim-truncated block of this message by id.
    var onHydrateBlock: ((_ blockId: String) -> Void)? = nil
    /// Agent-to-agent rows render as a collapsed disclosure card; the body
    /// is hidden until the header is tapped (FE parity: ChatMessage.svelte
    /// `isAgentMessageExpanded`, collapsed by default).
    @State private var isAgentMessageExpanded = false

    private var isUser: Bool { message.role == .user }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Dismissal notification rows render as a compact divider chip
            // regardless of the persisted role (PROTOCOL §5.5
            // `questions_dismissed`; FE parity: ChatMessage.svelte).
            if let dismissedNotice = message.questionsDismissedNotice {
                QuestionsDismissedNoticeView(notice: dismissedNotice)
            } else if let modelChange = message.modelChangeNotice {
                // Model-change rows (`metadata.type = "model_changed"`) are
                // informational and render as a centered divider chip
                // regardless of the persisted role (PROTOCOL §5.5
                // `agent.setModel`; FE parity: ChatMessage.svelte checks
                // getModelChangeNotice before any role branching).
                ModelChangeNoticeView(
                    notice: modelChange, fallbackText: message.joinedTextContent)
            } else if isUser, let eventWake = message.eventWakeAttribution {
                // Event-notification wake rows render as a compact banner —
                // the whole body is machine text, so the banner replaces the
                // bubble (display-only; FE parity: EventWakeupBanner).
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
                // Attention-request / turn-failure rows get a kind-flavored
                // card; every other system row (e.g. `meta.kind =
                // "interruption"`) falls back to a generic muted banner
                // instead of rendering nothing (FE parity:
                // ChatMessage.svelte system branch).
                if let notice = message.attentionNotice {
                    AttentionNoticeView(notice: notice)
                } else {
                    SystemNoticeBannerView(message: message.joinedTextContent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}