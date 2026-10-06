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
    @State private var submitting = false
    @Namespace private var questionSurface
    @AccessibilityFocusState private var panelFocused: Bool

    private typealias Design = Constants.Conversation.Design

    private var isActive: Bool {
        isEnabled && isPresented && viewModel.pendingQuestions != nil
    }

    private var collapsed: Binding<Bool> {
        Binding(get: { !isActive }, set: { isPresented = !$0 })
    }

    private var presentationAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: Design.Question.presentationCrossfadeDuration)
            : Design.Question.transitionAnimation
    }

    func body(content: Content) -> some View {
        content
            .blur(radius: isActive && !reduceTransparency ? Design.Question.backdropBlur : 0)
            .allowsHitTesting(!isActive && !submitting)
            .accessibilityElement(children: .contain)
            .accessibilityHidden(isActive || submitting)
            .overlay {
                if isEnabled, let pending = viewModel.pendingQuestions {
                    ZStack(alignment: .bottom) {
                        (reduceTransparency ? Design.Palette.surface(for: colorScheme) : Color.black.opacity(Design.Question.backdropOpacity))
                            .ignoresSafeArea()
                            .contentShape(.rect)
                            .opacity(isActive ? 1 : 0)
                            .accessibilityHidden(true)
                        QuestionWizardView(
                            questions: pending.questions,
                            collapsed: collapsed,
                            workspaceAvailableHeight: max(0, availableHeight - Design.Question.modalTopInset),
                            onComplete: { submit($0, messageId: pending.messageId) },
                            onCollapse: { isPresented = false }
                        )
                        .id(pending.messageId)
                        .opacity(isActive ? 1 : 0)
                        .accessibilityElement(children: .contain)
                        .accessibilityHidden(!isActive)
                        .accessibilityAddTraits(.isModal)
                        .accessibilityFocused($panelFocused)
                        .accessibilityAction(.escape) { isPresented = false }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { availableHeight = $0 }
                    .allowsHitTesting(isActive)
                    .accessibilityHidden(!isActive)
                }
            }
            .environment(\.workspaceQuestionNamespace, reduceMotion ? nil : questionSurface)
            .environment(\.workspaceQuestionPanelPresented, isActive)
            .environment(\.workspaceQuestionSubmitting, submitting)
            .animation(presentationAnimation, value: isActive)
            .onChange(of: isActive) { _, active in panelFocused = active }
            .onChange(of: viewModel.pendingQuestions?.messageId) { _, _ in isPresented = false }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { isPresented = false }
            }
    }

    private func submit(_ answers: [QuestionAnswer], messageId: String) {
        guard !submitting else { return }
        // Keep the banner's layout destination until the panel has collapsed,
        // but fade its content away rather than flashing it before the send.
        withAnimation(presentationAnimation, completionCriteria: .removed) {
            submitting = true
            isPresented = false
        } completion: {
            Task {
                await viewModel.submitQuestionAnswers(answers, answeredQuestionsMessageId: messageId)
                submitting = false
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var workspaceQuestionNamespace: Namespace.ID?
    @Entry var workspaceQuestionPanelPresented = false
    @Entry var workspaceQuestionSubmitting = false
}

/// The surface changes size while its whole contents travel with its top edge.
/// Matching position only keeps the header and controls at their natural sizes.
struct WorkspaceQuestionSurface: ViewModifier {
    var isPanel = true
    @Environment(\.workspaceQuestionNamespace) private var namespace
    @Environment(\.workspaceQuestionPanelPresented) private var panelPresented
    @Environment(\.colorScheme) private var colorScheme

    private typealias Design = Constants.Conversation.Design

    func body(content: Content) -> some View {
        positionedContent(content).background {
            if let namespace {
                if panelPresented == isPanel {
                    RoundedRectangle(cornerRadius: Design.cornerRadius)
                        .fill(Design.Palette.surface(for: colorScheme))
                        .matchedGeometryEffect(id: "question-surface", in: namespace)
                }
            } else {
                RoundedRectangle(cornerRadius: Design.cornerRadius)
                    .fill(Design.Palette.surface(for: colorScheme))
            }
        }
    }

    @ViewBuilder
    private func positionedContent(_ content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(
                id: "question-content",
                in: namespace,
                properties: .position,
                anchor: .topLeading,
                isSource: panelPresented == isPanel
            )
        } else {
            content
        }
    }
}
