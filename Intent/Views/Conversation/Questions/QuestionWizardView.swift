import SwiftUI

/// Sequential Agent Q&A wizard rendered in the composer slot. The host
/// remounts it whenever a different question set pends.
struct QuestionWizardView: View {
    let questions: [Question]
    @Binding var collapsed: Bool
    let containerHeight: CGFloat
    let onComplete: ([QuestionAnswer]) -> Void
    var onDismiss: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private struct DraftAnswer {
        var sel: [Int] = []
        var text: String = ""
        var skipped: Bool = false
    }

    @State private var idx = 0
    @State private var drafts: [DraftAnswer]
    @State private var submitted = false
    @State private var confirmingDismiss = false
    @State private var dismissed = false
    @State private var stepContentHeights: [Int: CGFloat] = [:]

    init(
        questions: [Question],
        collapsed: Binding<Bool>,
        containerHeight: CGFloat = 0,
        onComplete: @escaping ([QuestionAnswer]) -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        self.questions = questions
        self._collapsed = collapsed
        self.containerHeight = containerHeight
        self.onComplete = onComplete
        self.onDismiss = onDismiss
        _drafts = State(initialValue: questions.map { _ in DraftAnswer() })
    }

    private var current: Question { questions[idx] }
    private var isLast: Bool { idx == questions.count - 1 }
    private var isMulti: Bool { current.multiSelect }
    private var multiStep: Bool { questions.count > 1 }
    private var showNext: Bool { isMulti || isLast }
    private var nextDisabled: Bool {
        (isMulti || isLast) && drafts[idx].sel.isEmpty
            && drafts[idx].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if questions.isEmpty {
                EmptyView()
            } else if collapsed {
                QuestionWizardCollapsedBanner(
                    questionCount: questions.count,
                    showsDismiss: onDismiss != nil,
                    dismissed: dismissed,
                    onExpand: { collapsed = false },
                    onDismiss: { confirmingDismiss = true }
                )
            } else {
                QuestionWizardHeaderRow(
                    questionCount: questions.count,
                    index: idx,
                    isMulti: isMulti,
                    showsDismiss: onDismiss != nil,
                    dismissed: dismissed,
                    onIgnore: { collapsed = true },
                    onDismiss: { confirmingDismiss = true }
                )
                QuestionStepView(
                    step: idx,
                    question: current,
                    selectedIndices: $drafts[idx].sel,
                    freeText: $drafts[idx].text,
                    isMulti: isMulti,
                    contentHeight: stepContentHeights[idx],
                    maximumHeight: stepBodyMaxHeight,
                    onContentHeight: { step, height in
                        stepContentHeights[step] = height
                    },
                    onSelect: selectOption,
                    onSubmit: handleNext,
                    onTextChange: markCurrentDraftUnskipped
                )
                    .id(idx)
                    .transition(.opacity)
                QuestionWizardFooterRow(
                    index: idx,
                    multiStep: multiStep,
                    isMulti: isMulti,
                    isLast: isLast,
                    showNext: showNext,
                    nextDisabled: nextDisabled,
                    submitted: submitted,
                    dismissed: dismissed,
                    onBack: handleBack,
                    onSkip: handleSkip,
                    onNext: handleNext
                )
            }
        }
        .background(Theme.muted(for: colorScheme).opacity(
            colorSchemeContrast == .increased ? 0.7 : 0.4
        ))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    Theme.border(for: colorScheme, contrast: colorSchemeContrast).opacity(
                        colorSchemeContrast == .increased ? 1 : 0.3
                    ),
                    lineWidth: colorSchemeContrast == .increased ? 2 : 1
                )
        )
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: Constants.Conversation.QuestionWizard.animationDuration), value: idx)
        .animation(.easeInOut(duration: Constants.Conversation.QuestionWizard.animationDuration), value: collapsed)
        .confirmationDialog(
            "Dismiss questions?",
            isPresented: $confirmingDismiss,
            titleVisibility: .visible
        ) {
            Button("Dismiss questions", role: .destructive) {
                guard !dismissed, !submitted else { return }
                dismissed = true
                onDismiss?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The agent's questions will be dismissed completely without "
                    + "answering. This is permanent — they won't come back, "
                    + "even after a reload."
            )
        }
    }

    private func buildAnswers() -> [QuestionAnswer] {
        zip(questions, drafts).map { question, draft in
            QuestionAnswer(
                question: question,
                selectedLabels: draft.sel.map { question.options[$0].label },
                freeText: draft.text.trimmingCharacters(in: .whitespacesAndNewlines),
                skipped: draft.skipped
            )
        }
    }

    private func advance() {
        if idx >= questions.count - 1 {
            guard !submitted, !dismissed else { return }
            submitted = true
            onComplete(buildAnswers())
            return
        }
        idx += 1
    }

    private func markCurrentDraftUnskipped() {
        drafts[idx].skipped = false
    }

    private func selectOption(_ optionIndex: Int) {
        if isMulti {
            if let position = drafts[idx].sel.firstIndex(of: optionIndex) {
                drafts[idx].sel.remove(at: position)
            } else {
                drafts[idx].sel.append(optionIndex)
            }
            drafts[idx].skipped = false
            return
        }
        drafts[idx].sel = drafts[idx].sel.contains(optionIndex) ? [] : [optionIndex]
        drafts[idx].skipped = false
        if isLast { return }
        advance()
    }

    private func handleNext() {
        if nextDisabled { return }
        advance()
    }

    private func handleSkip() {
        drafts[idx].sel = []
        drafts[idx].text = ""
        drafts[idx].skipped = true
        advance()
    }

    private func handleBack() {
        idx = max(idx - 1, 0)
    }

    private var stepBodyMaxHeight: CGFloat {
        containerHeight > 0
            ? containerHeight * Constants.Conversation.QuestionWizard.bodyHeightFraction
            : Constants.Conversation.QuestionWizard.fallbackBodyMaximumHeight
    }
}
