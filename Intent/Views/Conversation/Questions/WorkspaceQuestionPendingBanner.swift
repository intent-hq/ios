import SwiftUI

struct WorkspaceQuestionPendingBanner: View {
    let viewModel: ConversationViewModel
    let pendingSet: PendingQuestionSet
    let onAnswer: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmingDismiss = false
    @State private var dismissing = false

    private typealias Design = Constants.Conversation.Design

    var body: some View {
        QuestionWizardCollapsedBanner(
            questionCount: pendingSet.questions.count,
            showsDismiss: true,
            dismissed: dismissing,
            onExpand: onAnswer,
            onDismiss: { confirmingDismiss = true },
            usesWorkspaceDesign: true
        )
        .background(Design.Palette.surface(for: colorScheme), in: .rect(cornerRadius: Design.cornerRadius))
        .confirmationDialog("Dismiss questions?", isPresented: $confirmingDismiss, titleVisibility: .visible) {
            Button("Dismiss questions", role: .destructive) {
                dismissing = true
                Task {
                    await viewModel.dismissQuestions(messageId: pendingSet.messageId)
                    dismissing = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The agent's questions will be dismissed without answering. This cannot be undone.")
        }
    }
}
