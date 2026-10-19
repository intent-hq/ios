import SwiftUI

/// Sequential Agent Q&A wizard rendered in the composer slot or floating panel. The host
/// remounts it whenever a different question set pends.
struct QuestionWizardView: View {
    let questions: [Question]
    @Binding var collapsed: Bool
    let containerHeight: CGFloat
    /// Opt in only for the floating workspace panel. Supply its keyboard-safe
    /// available height; nil keeps the shared composer-slot behavior.
    let workspaceAvailableHeight: CGFloat?
    let attachments: ConversationAttachmentPipeline
    let workspaceId: String
    let isSubmitting: Bool
    let onComplete: ([QuestionAnswer]) -> Void
    var onDismiss: (() -> Void)?
    var onCollapse: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.conversationPresentation) private var presentation
    @Environment(\.isIPadPaneVisible) private var isIPadPaneVisible

    private typealias Layout = Constants.Conversation.QuestionWizard.Surface
    private typealias Design = Constants.Conversation.Design

    private struct DraftAnswer {
        var sel: [Int] = []
        var text: String = ""
        var skipped: Bool = false
    }

    @State private var idx = 0
    @State private var movingForward = true
    @State private var drafts: [DraftAnswer]
    @State private var confirmingDismiss = false
    @State private var dismissed = false
    @State private var stepContentHeights: [Int: CGFloat] = [:]
    @State private var answerFocused = false
    @State private var showsPhotos = false
    @State private var showsFiles = false
    @State private var answerComposerHeight: CGFloat = Constants.Conversation.Design.Composer.minimumHeight

    init(
        questions: [Question],
        collapsed: Binding<Bool>,
        attachments: ConversationAttachmentPipeline,
        workspaceId: String,
        containerHeight: CGFloat = 0,
        workspaceAvailableHeight: CGFloat? = nil,
        isSubmitting: Bool = false,
        onComplete: @escaping ([QuestionAnswer]) -> Void,
        onDismiss: (() -> Void)? = nil,
        onCollapse: (() -> Void)? = nil
    ) {
        self.questions = questions
        self._collapsed = collapsed
        self.containerHeight = containerHeight
        self.workspaceAvailableHeight = workspaceAvailableHeight
        self.attachments = attachments
        self.workspaceId = workspaceId
        self.isSubmitting = isSubmitting
        self.onComplete = onComplete
        self.onDismiss = onDismiss
        self.onCollapse = onCollapse
        _drafts = State(initialValue: questions.map { _ in DraftAnswer() })
    }

    private var current: Question { questions[idx] }
    private var submitted: Bool { isSubmitting || attachments.isLoadingPhotos || !attachments.selectedPhotoItems.isEmpty }
    private var isLast: Bool { idx == questions.count - 1 }
    private var isMulti: Bool { current.multiSelect }
    private var multiStep: Bool { questions.count > 1 }
    private var isPaneVisible: Bool { presentation != .iPad || isIPadPaneVisible }
    private var hasFreeText: Bool {
        !drafts[idx].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var nextDisabled: Bool {
        (workspaceAvailableHeight != nil || isMulti || isLast) && drafts[idx].sel.isEmpty && !hasFreeText
    }

    /// Whether the footer Next/Send button is visible. Free text on a
    /// single-select step has no advancing option tap, and Return inserts a
    /// newline where ComposerSubmitPolicy says so (iPhone), so the button is
    /// the submit path there.
    static func showsNext(isMulti: Bool, isLast: Bool, hasFreeText: Bool) -> Bool {
        isMulti || isLast || hasFreeText
    }

    var body: some View {
        Group {
            if let workspaceAvailableHeight, !questions.isEmpty {
                if !collapsed {
                    VStack(spacing: Design.Composer.keyboardBottomSpacing) {
                        QuestionCardPager(count: questions.count, index: idx, cornerRadius: Design.cornerRadius, movingForward: movingForward) { step in
                            WorkspaceQuestionStepView(
                                question: questions[step],
                                index: step,
                                questionCount: questions.count,
                                selectedIndices: drafts[step].sel,
                                availableHeight: max(0, workspaceAvailableHeight - answerComposerHeight - Design.Composer.keyboardBottomSpacing * 2),
                                onSelect: selectOption,
                                footer: footer(for: step, usesWorkspaceDesign: true),
                                onCollapse: onCollapse
                            )
                        }
                        .modifier(WorkspaceQuestionSurface())
                        workspaceAnswerComposer
                    }
                    .disabled(submitted)
                    .padding(.horizontal, answerFocused ? Design.Composer.keyboardHorizontalInset : Design.horizontalInset)
                    .padding(.bottom, Design.Composer.keyboardBottomSpacing)
                }
            } else {
                legacyWizard
            }
        }
        .disabled(submitted)
        .modifier(QuestionAttachmentPickers(
            attachments: attachments,
            workspaceId: workspaceId,
            showsPhotos: $showsPhotos,
            showsFiles: $showsFiles
        ))
        .onChange(of: collapsed) { _, collapsed in
            if collapsed { answerFocused = false }
        }
        .onChange(of: isPaneVisible) { _, visible in
            if !visible { answerFocused = false }
        }
        .animation(
            reduceMotion
                ? .easeOut(duration: Constants.Conversation.QuestionWizard.Paging.crossfadeDuration)
                : Design.Question.transitionAnimation,
            value: idx
        )
    }

    private var workspaceAnswerComposer: some View {
        VStack(spacing: 0) {
            QuestionAttachmentTray(attachments: attachments)
            WorkspaceQuestionFreeText(
                text: $drafts[idx].text,
                focused: $answerFocused,
                isLast: isLast,
                onSubmit: handleNext,
                onTextChange: markCurrentDraftUnskipped,
                onPhotos: { showsPhotos = true },
                onFiles: { showsFiles = true },
                onPasteImages: attachments.pasteImages
            )
        }
        .background(Design.Palette.surface(for: colorScheme), in: .rect(cornerRadius: Design.cornerRadius))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { answerComposerHeight = $0 }
    }

    private var legacyWizard: some View {
        VStack(alignment: .leading, spacing: 0) {
            wizardContent
        }
        .background(surfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: surfaceCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: surfaceCornerRadius)
                .strokeBorder(
                    surfaceBorder,
                    lineWidth: colorSchemeContrast == .increased ? Layout.increasedBorderWidth : Layout.borderWidth
                )
        )
        .frame(maxWidth: .infinity)
        .animation(wizardAnimation, value: collapsed)
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

    @ViewBuilder
    private var wizardContent: some View {
        if questions.isEmpty {
            EmptyView()
        } else if collapsed {
            QuestionWizardCollapsedBanner(
                questionCount: questions.count,
                showsDismiss: onDismiss != nil,
                dismissed: dismissed,
                onExpand: { collapsed = false },
                onDismiss: { confirmingDismiss = true },
                usesWorkspaceDesign: workspaceAvailableHeight != nil
            )
        } else {
            QuestionCardPager(count: questions.count, index: idx, cornerRadius: surfaceCornerRadius, movingForward: movingForward) { step in
                legacyCard(for: step)
            }
        }
    }

    private func legacyCard(for step: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            QuestionWizardHeaderRow(
                questionCount: questions.count,
                index: step,
                isMulti: questions[step].multiSelect,
                showsDismiss: onDismiss != nil,
                dismissed: dismissed,
                onIgnore: { collapsed = true },
                onDismiss: { confirmingDismiss = true }
            )
            QuestionStepView(
                step: step,
                question: questions[step],
                selectedIndices: $drafts[step].sel,
                freeText: $drafts[step].text,
                isMulti: questions[step].multiSelect,
                contentHeight: stepContentHeights[step],
                maximumHeight: stepBodyMaxHeight,
                onContentHeight: { step, height in
                    stepContentHeights[step] = height
                },
                onSelect: selectOption,
                onSubmit: handleNext,
                onTextChange: { drafts[step].skipped = false },
                isActive: step == idx && !collapsed && isPaneVisible,
                onPhotos: { showsPhotos = true },
                onFiles: { showsFiles = true },
                onPasteImages: attachments.pasteImages
            )
            QuestionAttachmentTray(attachments: attachments)
            footer(for: step)
        }
    }

    private func footer(for step: Int, usesWorkspaceDesign: Bool = false) -> some View {
        let isMulti = questions[step].multiSelect
        let isLast = step == questions.count - 1
        let hasText = !drafts[step].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return QuestionWizardFooterRow(
            index: step,
            multiStep: multiStep,
            isMulti: isMulti,
            isLast: isLast,
            showNext: usesWorkspaceDesign || Self.showsNext(isMulti: isMulti, isLast: isLast, hasFreeText: hasText),
            nextDisabled: (usesWorkspaceDesign || isMulti || isLast) && drafts[step].sel.isEmpty && !hasText,
            submitted: submitted,
            dismissed: dismissed,
            onBack: handleBack,
            onSkip: handleSkip,
            onNext: handleNext,
            usesWorkspaceDesign: usesWorkspaceDesign,
            backVisible: idx > 0
        )
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
            onComplete(buildAnswers())
            return
        }
        movingForward = true
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
        if isLast || workspaceAvailableHeight != nil { return }
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
        movingForward = false
        idx = max(idx - 1, 0)
    }
}

extension QuestionWizardView {
    private var stepBodyMaxHeight: CGFloat {
        containerHeight > 0
            ? containerHeight * Constants.Conversation.QuestionWizard.bodyHeightFraction
            : Constants.Conversation.QuestionWizard.fallbackBodyMaximumHeight
    }

    private var surfaceColor: Color {
        workspaceAvailableHeight != nil
            ? Design.Palette.surface(for: colorScheme)
            : Theme.muted(for: colorScheme).opacity(
                colorSchemeContrast == .increased ? Layout.backgroundIncreasedOpacity : Layout.backgroundOpacity
            )
    }

    private var surfaceCornerRadius: CGFloat {
        workspaceAvailableHeight != nil ? Design.cornerRadius : Layout.cornerRadius
    }

    private var surfaceBorder: Color {
        if workspaceAvailableHeight != nil {
            return colorSchemeContrast == .increased
                ? Design.Palette.border(for: colorScheme, contrast: colorSchemeContrast) : .clear
        }
        return Theme.border(for: colorScheme, contrast: colorSchemeContrast).opacity(
            colorSchemeContrast == .increased ? 1 : Layout.standardBorderOpacity
        )
    }

    private var wizardAnimation: Animation? {
        if reduceMotion {
            return workspaceAvailableHeight != nil
                ? nil : .easeInOut(duration: Constants.Conversation.QuestionWizard.animationDuration)
        }
        return Design.Question.transitionAnimation
    }
}
