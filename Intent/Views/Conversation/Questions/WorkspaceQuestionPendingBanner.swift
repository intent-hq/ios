import SwiftUI

struct WorkspaceQuestionPendingBanner: View {
    let viewModel: ConversationViewModel
    let pendingSet: PendingQuestionSet
    let onAnswer: () -> Void

    @Environment(\.workspaceQuestionPanelPresented) private var panelPresented
    @Environment(\.workspaceQuestionSubmitting) private var submitting
    @State private var confirmingDismiss = false
    @State private var dismissing = false
    @AccessibilityFocusState private var bannerFocused: Bool

    var body: some View {
        QuestionWizardCollapsedBanner(
            questionCount: pendingSet.questions.count,
            showsDismiss: true,
            dismissed: dismissing,
            onExpand: onAnswer,
            onDismiss: { confirmingDismiss = true },
            usesWorkspaceDesign: true
        )
        .opacity(panelPresented ? 0 : 1)
        .modifier(WorkspaceQuestionSurface(isPanel: false))
        .opacity(submitting ? 0 : 1)
        .allowsHitTesting(!panelPresented && !submitting)
        .accessibilityElement(children: .contain)
        .accessibilityHidden(panelPresented || submitting)
        .accessibilityFocused($bannerFocused)
        .onChange(of: panelPresented) { wasPresented, presented in
            if wasPresented, !presented, !submitting { bannerFocused = true }
        }
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
