import SwiftUI

/// One transcript row. A thin shell over `MessageRowContent`: the transcript
/// hands every row fresh closures on each evaluation, so the row body is
/// gated by `.equatable()` and only re-renders when its message, workspace,
/// or hydration set actually changed — not on every streaming delta.
struct MessageView: View {
    let message: ConversationMessage
    let workspaceId: String
    var onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)?
    var onNavigateToAgent: ((_ agentId: String, _ workspaceId: String, _ agentName: String) -> Void)?
    /// Block ids of this message with a slim-projection hydration fetch in
    /// flight (agent.getMessageBlock, PROTOCOL §5.5).
    var hydratingBlockIds: Set<String> = []
    /// Invalidates the transcript's settled height before local disclosure
    /// state changes the row's layout.
    var onLayoutChange: (() -> Void)?
    /// Fetch the full body of a slim-truncated block of this message by id.
    var onHydrateBlock: ((_ blockId: String) -> Void)?

    var body: some View {
        MessageRowContent(
            message: message,
            workspaceId: workspaceId,
            onNavigateToNote: onNavigateToNote,
            onNavigateToAgent: onNavigateToAgent,
            hydratingBlockIds: hydratingBlockIds,
            onLayoutChange: onLayoutChange,
            onHydrateBlock: onHydrateBlock
        )
        .equatable()
    }
}

/// The value-compared row body behind `MessageView`.
struct MessageRowContent: View, Equatable {
    let message: ConversationMessage
    let workspaceId: String
    var onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)?
    var onNavigateToAgent: ((_ agentId: String, _ workspaceId: String, _ agentName: String) -> Void)?
    var hydratingBlockIds: Set<String>
    var onLayoutChange: (() -> Void)?
    var onHydrateBlock: ((_ blockId: String) -> Void)?
    /// Agent-to-agent rows render as a collapsed disclosure card; the body
    /// is hidden until the header is tapped (FE parity: ChatMessage.svelte
    /// `isAgentMessageExpanded`, collapsed by default).
    @State private var isAgentMessageExpanded = false

    /// Manual `==`: closures are excluded on purpose — the transcript builds
    /// new ones per evaluation, and they only capture stable identifiers.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message
            && lhs.workspaceId == rhs.workspaceId
            && lhs.hydratingBlockIds == rhs.hydratingBlockIds
    }

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
                    notice: modelChange,
                    fallbackText: message.joinedTextContent
                )
            } else if isUser, let eventWake = message.eventWakeAttribution {
                // Event-notification wake rows render as a compact banner —
                // the whole body is machine text, so the banner replaces the
                // bubble (display-only; FE parity: EventWakeupBanner).
                EventWakeBannerView(attribution: eventWake)
            } else if isUser {
                userMessage
            } else if message.role == .assistant {
                AssistantMessageView(
                    message: message,
                    workspaceId: workspaceId,
                    onNavigateToNote: onNavigateToNote,
                    hydratingBlockIds: hydratingBlockIds,
                    onLayoutChange: onLayoutChange,
                    onHydrateBlock: onHydrateBlock
                )
            } else if message.role == .error {
                ErrorMessageView(message: message)
            } else if message.role == .system {
                systemMessage
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var userMessage: some View {
        UserMessageView(
            message: message,
            workspaceId: workspaceId,
            onNavigateToAgent: onNavigateToAgent,
            isAgentMessageExpanded: agentMessageExpansion,
            onLayoutChange: onLayoutChange
        )
    }

    private var agentMessageExpansion: Binding<Bool> {
        Binding(
            get: { isAgentMessageExpanded },
            set: { expanded in
                onLayoutChange?()
                isAgentMessageExpanded = expanded
            }
        )
    }

    @ViewBuilder
    private var systemMessage: some View {
        // Attention-request / turn-failure rows get a kind-flavored card;
        // every other system row falls back to a generic muted banner.
        if let notice = message.attentionNotice {
            AttentionNoticeView(notice: notice, onLayoutChange: onLayoutChange)
        } else {
            SystemNoticeBannerView(message: message.joinedTextContent)
        }
    }
}
