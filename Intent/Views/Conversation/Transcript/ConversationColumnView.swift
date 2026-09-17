import SwiftUI

struct ConversationColumnView: View {
    let viewModel: ConversationViewModel
    let onNavigateToNote: (String, String, String) -> Void
    let onNavigateToAgent: (String, String, String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var questionWizardCollapsed = false
    @State private var conversationHeight: CGFloat = 0
    @State private var transcriptScrollState = ConversationTranscriptScrollState()

    private enum Layout {
        static let questionBannerBackgroundOpacity: Double = 0.4
        static let questionBannerCornerRadius: CGFloat = 12
        static let questionBannerHorizontalPadding: CGFloat = 8
        static let questionBannerVerticalPadding: CGFloat = 8
        static let questionWizardHorizontalPadding: CGFloat = 8
        static let questionWizardTopPadding: CGFloat = 8
        static let collapsedQuestionWizardBottomPadding: CGFloat = 4
        static let expandedQuestionWizardBottomPadding: CGFloat = 8
        static let questionSheetPadding: CGFloat = 24
    }

    #if os(visionOS)
    // visionOS presents structured questions as a deliberate sheet instead
    // of the inline composer-slot wizard; the inline slot shows an opener.
    @State private var questionSheetPresented = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            columnContent
        }
        // Measured inside keyboard avoidance on purpose: with the keyboard
        // up the cap derives from the remaining visible height.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            conversationHeight = height
        }
        .onChange(of: viewModel.pendingQuestions?.messageId) { _, newId in
            questionWizardCollapsed = false
            #if os(visionOS)
            // Auto-present on a new question set; close when the set clears
            // (answered/dismissed elsewhere, or superseded).
            questionSheetPresented = newId != nil
            #endif
        }
        #if os(visionOS)
        .onAppear {
            questionSheetPresented = viewModel.pendingQuestions != nil
        }
        .sheet(isPresented: $questionSheetPresented) {
            questionSheet
        }
        #endif
        .background(Theme.background(for: colorScheme).ignoresSafeArea())
        .animation(
            .easeInOut(duration: Constants.Conversation.Column.chromeAnimationDuration),
            value: viewModel.store.isWaitingForAgents
        )
        .animation(
            .easeInOut(duration: Constants.Conversation.Column.chromeAnimationDuration),
            value: viewModel.activeAgentHooks.map(\.hookId)
        )
        .animation(
            .easeInOut(duration: Constants.Conversation.Column.chromeAnimationDuration),
            value: viewModel.activeAgentMonitors.map(\.monitorId)
        )
    }

    @ViewBuilder
    private var columnContent: some View {
        if let attention = viewModel.attentionRequest {
            AttentionRequestBanner(attention: attention)
            Divider()
        }

        if viewModel.isLoading, viewModel.filteredMessages.isEmpty {
            ConversationLoadingView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.filteredMessages.isEmpty {
            ConversationEmptyView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ConversationTranscriptView(
                viewModel: viewModel,
                scrollState: transcriptScrollState,
                onNavigateToNote: onNavigateToNote,
                onNavigateToAgent: onNavigateToAgent
            )
        }

        Divider()

        if viewModel.store.isWaitingForAgents {
            VStack(spacing: 0) {
                AgentWaitingView(
                    viewModel: viewModel,
                    store: viewModel.store,
                    onNavigateToAgent: onNavigateToAgent
                )
                Divider()
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }

        if !viewModel.activeAgentMonitors.isEmpty {
            VStack(spacing: 0) {
                MonitoredPrsRow(
                    viewModel: viewModel,
                    monitoredPrStore: viewModel.monitoredPrStore
                )
                Divider()
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }

        if !viewModel.activeAgentHooks.isEmpty {
            VStack(spacing: 0) {
                BackgroundHooksRow(
                    viewModel: viewModel,
                    hookStore: viewModel.hookStore
                )
                Divider()
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }

        if !viewModel.queuedMessages.isEmpty {
            QueuedMessagesView(viewModel: viewModel)
            Divider()
        }

        if let pendingSet = viewModel.pendingQuestions {
            #if os(visionOS)
            // Deliberate sheet presentation on visionOS: the inline slot is
            // only the opener banner; the wizard itself lives in the sheet.
            QuestionWizardCollapsedBanner(
                questionCount: pendingSet.questions.count,
                showsDismiss: false,
                dismissed: false,
                onExpand: { questionSheetPresented = true },
                onDismiss: {}
            )
            .background(Theme.muted(for: colorScheme).opacity(Layout.questionBannerBackgroundOpacity))
            .clipShape(RoundedRectangle(cornerRadius: Layout.questionBannerCornerRadius))
            .padding(.horizontal, Layout.questionBannerHorizontalPadding)
            .padding(.vertical, Layout.questionBannerVerticalPadding)
            #else
            QuestionWizardView(
                questions: pendingSet.questions,
                collapsed: $questionWizardCollapsed,
                containerHeight: conversationHeight,
                onComplete: { answers in
                    let answeredId = pendingSet.messageId
                    Task {
                        await viewModel.submitQuestionAnswers(
                            answers,
                            answeredQuestionsMessageId: answeredId
                        )
                    }
                },
                onDismiss: {
                    let dismissedId = pendingSet.messageId
                    Task {
                        await viewModel.dismissQuestions(messageId: dismissedId)
                    }
                }
            )
            .id(pendingSet.messageId)
            .padding(.horizontal, Layout.questionWizardHorizontalPadding)
            .padding(.top, Layout.questionWizardTopPadding)
            .padding(
                .bottom,
                questionWizardCollapsed
                    ? Layout.collapsedQuestionWizardBottomPadding
                    : Layout.expandedQuestionWizardBottomPadding
            )
            #endif
        }

        // Fail closed while the marked question row is being recovered from
        // outside the loaded page: no composer until the wizard can render
        // or the daemon clears/replaces the marker (FE parity: ChatPanel's
        // `pendingQuestionRecoveryLoading`). Collapse still reveals the
        // composer, as with a rendered wizard.
        if viewModel.isPendingQuestionRecoveryLoading, !questionWizardCollapsed {
            PendingQuestionRecoveryPlaceholder()
        }

        if composerVisible {
            MessageInputView(viewModel: viewModel, store: viewModel.store)
        }
    }

    /// On visionOS the wizard is a sheet, so the composer stays available
    /// under the opener banner and hides only during marker recovery. A
    /// `pendingQuestions != nil` check would be redundant: a derived set means
    /// the marked row is resident or recovered, so it implies
    /// `isPendingQuestionRecoveryLoading` is false (invariant pinned by
    /// PendingQuestionRecoveryExclusivityTests). Elsewhere pending questions
    /// occupy the composer slot until collapsed.
    private var composerVisible: Bool {
        #if os(visionOS)
        return !viewModel.isPendingQuestionRecoveryLoading || questionWizardCollapsed
        #else
        return (viewModel.pendingQuestions == nil && !viewModel.isPendingQuestionRecoveryLoading)
            || questionWizardCollapsed
        #endif
    }

    #if os(visionOS)
    @ViewBuilder
    private var questionSheet: some View {
        if let pendingSet = viewModel.pendingQuestions {
            QuestionWizardView(
                questions: pendingSet.questions,
                collapsed: Binding(
                    get: { false },
                    set: { if $0 { questionSheetPresented = false } }
                ),
                onComplete: { answers in
                    let answeredId = pendingSet.messageId
                    questionSheetPresented = false
                    Task {
                        await viewModel.submitQuestionAnswers(
                            answers,
                            answeredQuestionsMessageId: answeredId
                        )
                    }
                },
                onDismiss: {
                    let dismissedId = pendingSet.messageId
                    questionSheetPresented = false
                    Task {
                        await viewModel.dismissQuestions(messageId: dismissedId)
                    }
                }
            )
            .id(pendingSet.messageId)
            .padding(Layout.questionSheetPadding)
            .presentationDetents([.medium, .large])
        }
    }
    #endif
}

private struct PendingQuestionRecoveryPlaceholder: View {
    @Environment(\.colorScheme) private var colorScheme

    private enum Layout {
        static let contentSpacing: CGFloat = 8
        static let verticalPadding: CGFloat = 12
    }

    var body: some View {
        HStack(spacing: Layout.contentSpacing) {
            ProgressView()
                .controlSize(.small)
            Text("Loading questions...")
                .font(.subheadline)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Layout.verticalPadding)
        .accessibilityElement(children: .combine)
    }
}

private struct ConversationLoadingView: View {
    @Environment(\.colorScheme) private var colorScheme

    private enum Layout {
        static let contentSpacing: CGFloat = 12
    }

    var body: some View {
        VStack(spacing: Layout.contentSpacing) {
            ProgressView()
            Text("Loading conversation...")
                .font(.subheadline)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
    }
}

private struct ConversationEmptyView: View {
    let viewModel: ConversationViewModel
    @Environment(\.colorScheme) private var colorScheme

    private enum Layout {
        static let contentSpacing: CGFloat = 12
        static let descriptionHorizontalPadding: CGFloat = 32
        static let modelCaptionOpacity: Double = 0.7
        static let modelCaptionTopPadding: CGFloat = 4
    }

    var body: some View {
        if let name = viewModel.specialistName {
            VStack(spacing: Layout.contentSpacing) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .accessibilityHidden(true)
                Text(name)
                    .font(.headline)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                if let description = viewModel.specialistDescription {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Layout.descriptionHorizontalPadding)
                }
                if let displayName = viewModel.currentModelDisplayName {
                    Text("Using \(displayName)")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(Layout.modelCaptionOpacity))
                        .padding(.top, Layout.modelCaptionTopPadding)
                }
            }
        } else {
            VStack(spacing: Layout.contentSpacing) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .accessibilityHidden(true)
                Text("No messages yet")
                    .font(.headline)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                Text("Messages will appear here as the agent works.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                if let displayName = viewModel.currentModelDisplayName {
                    Text("Using \(displayName)")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(Layout.modelCaptionOpacity))
                        .padding(.top, Layout.modelCaptionTopPadding)
                }
            }
        }
    }
}
