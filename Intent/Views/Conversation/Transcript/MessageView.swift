import SwiftUI

struct MessageView: View {
    @Environment(\.collapseToolActivity) private var collapseToolActivity

    let message: ConversationMessage
    let workspaceId: String
    var onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)?
    var onNavigateToAgent: ((_ agentId: String, _ workspaceId: String, _ agentName: String) -> Void)?
    var hydratingBlockIds: Set<String> = []
    var onLayoutChange: (() -> Void)?
    var onHydrateBlock: ((_ blockId: String) -> Void)?

    var body: some View {
        MessageRowContent(
            message: message,
            workspaceId: workspaceId,
            onNavigateToNote: onNavigateToNote,
            onNavigateToAgent: onNavigateToAgent,
            hydratingBlockIds: hydratingBlockIds,
            collapseToolActivity: message.role == .assistant && collapseToolActivity,
            onLayoutChange: onLayoutChange,
            onHydrateBlock: onHydrateBlock
        )
        .equatable()
    }
}

struct MessageRowContent: View, Equatable {
    let message: ConversationMessage
    let workspaceId: String
    var onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)?
    var onNavigateToAgent: ((_ agentId: String, _ workspaceId: String, _ agentName: String) -> Void)?
    var hydratingBlockIds: Set<String>
    var collapseToolActivity = true
    var onLayoutChange: (() -> Void)?
    var onHydrateBlock: ((_ blockId: String) -> Void)?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message
            && lhs.workspaceId == rhs.workspaceId
            && lhs.hydratingBlockIds == rhs.hydratingBlockIds
            && lhs.collapseToolActivity == rhs.collapseToolActivity
    }

    private var isUser: Bool { message.role == .user }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let dismissedNotice = message.questionsDismissedNotice {
                QuestionsDismissedNoticeView(notice: dismissedNotice)
            } else if let goalNotice = message.goalCommandNotice {
                GoalCommandNoticeView(notice: goalNotice)
            } else if let modelChange = message.modelChangeNotice {
                ModelChangeNoticeView(
                    notice: modelChange,
                    fallbackText: message.joinedTextContent
                )
            } else if isUser, let eventWake = message.eventWakeAttribution {
                EventWakeBannerView(attribution: eventWake)
            } else if isUser {
                userMessage
            } else if message.role == .assistant {
                AssistantMessageView(
                    message: message,
                    workspaceId: workspaceId,
                    onNavigateToNote: onNavigateToNote,
                    hydratingBlockIds: hydratingBlockIds,
                    collapseToolActivity: collapseToolActivity,
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
            onLayoutChange: onLayoutChange
        )
    }

    @ViewBuilder
    private var systemMessage: some View {
        if let notice = message.attentionNotice {
            AttentionNoticeView(notice: notice, onLayoutChange: onLayoutChange)
        } else {
            SystemNoticeBannerView(message: message.joinedTextContent)
        }
    }
}
