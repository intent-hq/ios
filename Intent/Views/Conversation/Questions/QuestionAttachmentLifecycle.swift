import SwiftUI

/// Retirement is not disappearance: streaming and a collapsed card keep drafts.
struct QuestionAttachmentLifecycle: ViewModifier {
    let viewModel: ConversationViewModel

    func body(content: Content) -> some View {
        content.onChange(of: viewModel.retiredQuestionAttachmentMessageIds, initial: true) { _, ids in
            for id in ids { viewModel.discardQuestionAttachments(for: id) }
        }
    }
}

extension ConversationViewModel {
    var retiredQuestionAttachmentMessageIds: Set<String> {
        // Read the signals even before the first pipeline is created. The
        // pipeline dictionary itself is intentionally not observable.
        let submitting = submittingQuestionMessageIds
        let dismissed = store.dismissedQuestionsMessageId
        let messages = messages
        let queued = store.queuedMessages
        let marker = PendingQuestionSet.MarkerState(store.pendingQuestionsMessageId)
        let streaming = isStreaming
        return Set(questionAttachmentPipelines.keys.filter { id in
            // Optimistic local answer rows may roll back; the send owns cleanup.
            guard !submitting.contains(id) else { return false }
            if dismissed == id
                || PendingQuestionSet.isQuestionSetAnswered(messages: messages, messageId: id)
                || queued.contains(where: { $0.answeredQuestionsMessageId == id }) {
                return true
            }
            switch marker {
            case .cleared: return true
            case .set(let markedId): return markedId != id
            case .absent:
                // A legacy turn can temporarily hide its question-bearing tail.
                guard !streaming, let tail = messages.last(where: { $0.role != .system }),
                      tail.isStreaming != true else { return false }
                return tail.id != id
            }
        })
    }
}
