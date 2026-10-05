import SwiftUI

/// Keeps the live conversation mounted beneath a deliberate, blocking answer surface.
struct WorkspaceQuestionPresentation: ViewModifier {
    let viewModel: ConversationViewModel
    @Binding var isPresented: Bool
    let isEnabled: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var availableHeight: CGFloat = 0

    private typealias Design = Constants.Conversation.Design

    private var isActive: Bool {
        isEnabled && isPresented && viewModel.pendingQuestions != nil
    }

    private var modalPresented: Binding<Bool> {
        Binding(get: { isActive }, set: { isPresented = $0 })
    }

    func body(content: Content) -> some View {
        content
            .blur(radius: isActive && !reduceTransparency ? Design.Question.backdropBlur : 0)
            .allowsHitTesting(!isActive)
            .fullScreenCover(isPresented: modalPresented) {
                if let pending = viewModel.pendingQuestions {
                    ZStack(alignment: .bottom) {
                        (reduceTransparency ? Design.Palette.surface(for: colorScheme) : Color.black.opacity(Design.Question.backdropOpacity))
                            .ignoresSafeArea()
                            .contentShape(.rect)
                            .accessibilityHidden(true)
                        QuestionWizardView(
                            questions: pending.questions,
                            collapsed: .constant(false),
                            workspaceAvailableHeight: max(0, availableHeight - Design.Question.modalTopInset)
                        ) { answers in
                            isPresented = false
                            Task {
                                await viewModel.submitQuestionAnswers(answers, answeredQuestionsMessageId: pending.messageId)
                            }
                        }
                        .id(pending.messageId)
                        .accessibilityElement(children: .contain)
                        .accessibilityAddTraits(.isModal)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { availableHeight = $0 }
                    .presentationBackground(.clear)
                    .interactiveDismissDisabled()
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: Constants.Conversation.QuestionWizard.animationDuration), value: isActive)
            .onChange(of: viewModel.pendingQuestions?.messageId) { _, _ in isPresented = false }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { isPresented = false }
            }
    }
}
