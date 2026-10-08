import SwiftUI

struct ConversationColumnView: View {
    let viewModel: ConversationViewModel
    let onNavigateToNote: (String, String, String) -> Void
    let onNavigateToAgent: (String, String, String) -> Void
    var usesWorkspaceDesign = false
    @Binding var answeringWorkspaceQuestions: Bool
    var onDemoCover: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @State private var questionWizardCollapsed = false
    @State private var conversationHeight: CGFloat = 0
    @State private var questionInputTop: CGFloat?
    @State private var composerInputTop: CGFloat?
    @State private var composerFocused = false
    @State private var keyboardVisible = false
    @State private var transcriptScrollState = ConversationTranscriptScrollState()

    private typealias Layout = Constants.Conversation.Column
    private typealias Design = Constants.Conversation.Design

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
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        .onChange(of: viewModel.pendingQuestions?.messageId) { _, newId in
            questionWizardCollapsed = false
            #if os(visionOS)
            // Auto-present on a new question set; close when the set clears
            // (answered/dismissed elsewhere, or superseded).
            questionSheetPresented = newId != nil
            #endif
        }
        .onChange(of: viewModel.filteredMessageIDs, initial: true) { _, messageIDs in
            transcriptScrollState.rowHeightCache.retainMessages(withIDs: messageIDs)
            transcriptScrollState.retainViewportMessages(withIDs: messageIDs)
        }
        #if os(visionOS)
        .onAppear {
            questionSheetPresented = viewModel.pendingQuestions != nil
        }
        .sheet(isPresented: $questionSheetPresented) {
            questionSheet
        }
        #endif
        .animation(.easeInOut(duration: Layout.Loading.fadeDuration), value: viewModel.showsLoadingState)
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
        if DemoMode.isEnabled, DemoFixtures.usesStartupTranscript || DemoFixtures.usesHistoryPages {
            Button("Open conversation cover", action: onDemoCover)
                .buttonStyle(IntentButtonStyle(variant: .secondary))
                .accessibilityIdentifier("demo.conversation.cover")
                .accessibilityValue(
                    "metadata=\(viewModel.store.metadataReadyForEntry ? "ready" : "pending") "
                        + "entry=\(viewModel.isEntryScrollReady ? "ready" : "pending") "
                        + "positioned=\(transcriptScrollState.hasInitiallyScrolled) "
                        + "anchor=\(viewModel.newMessagesDividerAnchorId ?? "none") consumer=\(viewModel.conversationConsumer)"
                )
        }
        ZStack {
            if viewModel.showsLoadingState {
                ConversationConnectionLoadingView(viewModel: viewModel, usesWorkspaceDesign: usesWorkspaceDesign)
                    .zIndex(1)
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
                .environment(\.workspaceTranscriptDesign, usesWorkspaceDesign)
                .overlay(alignment: .top) {
                    if usesWorkspaceDesign {
                        LinearGradient(
                            colors: [Design.Palette.background(for: colorScheme), Design.Palette.background(for: colorScheme).opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: Design.Header.fadeHeight)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
            }
        }
        // The conditional views use SwiftUI's default opacity transition.
        .animation(.easeInOut(duration: Layout.Loading.fadeDuration), value: viewModel.showsLoadingState)

        VStack(spacing: 0) {
            accessoryRows
        }

        questionRegion
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { questionInputTop = $0 }
            .preference(key: WorkspaceActionMenuInputTop.self, value: composerVisible || usesWorkspaceDesign ? nil : questionInputTop)
            .layoutPriority(usesWorkspaceDesign ? 1 : 0)

        if !viewModel.showsLoadingState, composerVisible || usesWorkspaceDesign {
            VStack(spacing: 0) {
                if usesWorkspaceDesign, !viewModel.activeAgentMonitors.isEmpty || viewModel.monitoredPrStore.error != nil {
                    MonitoredPrsRow(
                        viewModel: viewModel,
                        monitoredPrStore: viewModel.monitoredPrStore,
                        usesWorkspaceDesign: true
                    )
                    .padding(.horizontal, stickyHorizontalInset)
                    .padding(.top, Design.Composer.keyboardBottomSpacing)
                    .padding(.bottom, workspaceQueueVisible ? Design.Status.composerSpacing : 0)
                }
                WorkspaceQueuePanel(
                    viewModel: viewModel,
                    isVisible: workspaceQueueVisible,
                    horizontalInset: stickyHorizontalInset
                ) {
                    MessageInputView(
                        viewModel: viewModel,
                        store: viewModel.store,
                        usesWorkspaceDesign: usesWorkspaceDesign,
                        allowsSending: composerVisible
                    ) { composerFocused = $0 }
                    .disabled(usesWorkspaceDesign && answeringWorkspaceQuestions)
                    .padding(.horizontal, usesWorkspaceDesign ? stickyHorizontalInset : 0)
                    .padding(.top, usesWorkspaceDesign && !workspaceQueueVisible ? Design.Composer.keyboardBottomSpacing : 0)
                    .padding(.bottom, usesWorkspaceDesign ? Design.Composer.keyboardBottomSpacing : 0)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { composerInputTop = $0 }
            .preference(key: WorkspaceActionMenuInputTop.self, value: composerInputTop)
        }
    }

    private var workspaceQueueVisible: Bool {
        usesWorkspaceDesign && !viewModel.queuedMessages.isEmpty
    }

    private var stickyHorizontalInset: CGFloat {
        keyboardVisible || composerFocused ? Design.Composer.keyboardHorizontalInset : Design.horizontalInset
    }

    @ViewBuilder
    private var accessoryRows: some View {
        if !usesWorkspaceDesign, !viewModel.showsLoadingState { Divider() }

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

        if !usesWorkspaceDesign, !viewModel.showsLoadingState,
           !viewModel.activeAgentMonitors.isEmpty || viewModel.monitoredPrStore.error != nil {
            VStack(spacing: 0) {
                MonitoredPrsRow(
                    viewModel: viewModel,
                    monitoredPrStore: viewModel.monitoredPrStore
                )
                Divider()
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }

        if !viewModel.activeAgentHooks.isEmpty || viewModel.hookStore.error != nil {
            VStack(spacing: 0) {
                BackgroundHooksRow(
                    viewModel: viewModel,
                    hookStore: viewModel.hookStore
                )
                Divider()
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }

        if !usesWorkspaceDesign, !viewModel.queuedMessages.isEmpty {
            QueuedMessagesView(viewModel: viewModel)
            Divider()
        }
    }

    @ViewBuilder
    private var questionRegion: some View {
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
            if usesWorkspaceDesign {
                WorkspaceQuestionPendingBanner(
                    viewModel: viewModel,
                    pendingSet: pendingSet
                ) {
                    answeringWorkspaceQuestions = true
                }
                .id(pendingSet.messageId)
                .padding(.horizontal, stickyHorizontalInset)
            } else {
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
            }
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

private struct ConversationConnectionLoadingView: View {
    let viewModel: ConversationViewModel
    let usesWorkspaceDesign: Bool

    private var message: LocalizedStringResource {
        switch viewModel.loadingStage {
        case .idle: "Loading conversation"
        case .connecting: "Connecting"
        case .requesting: "Requesting messages"
        case .receiving: "Receiving messages"
        case .retrying(let attempt): "Retrying (attempt \(attempt))"
        }
    }

    var body: some View {
        ScrollView {
            ConversationConnectionStatusBlock(
                phase: viewModel.loadingStage,
                message: message,
                currentStep: ConversationConnectionStep(stage: viewModel.loadingStage),
                startedAt: viewModel.loadingStartedAt,
                onRetry: viewModel.retryNow
            )
            .id(viewModel.conversationConsumer)
            .padding(.horizontal, usesWorkspaceDesign
                ? Constants.Conversation.Design.horizontalInset : Constants.Conversation.Transcript.transcriptHorizontalPadding)
            .padding(.vertical, Constants.Conversation.Transcript.transcriptTopPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Owned by the screen outside its top safe-area inset, not by the transcript slot.
struct ConversationBackground: View {
    let isLoading: Bool
    let usesWorkspaceDesign: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        (usesWorkspaceDesign ? Constants.Conversation.Design.Palette.background(for: colorScheme) : Theme.background(for: colorScheme))
            .ignoresSafeArea()
    }
}

private struct PendingQuestionRecoveryPlaceholder: View {
    @Environment(\.colorScheme) private var colorScheme

    private typealias Layout = Constants.Conversation.Column.PendingQuestionRecovery

    var body: some View {
        HStack(spacing: Layout.contentSpacing) {
            ProgressView()
                .controlSize(.small)
            Text("Loading questions...")
                .interFont(Constants.Typography.bodyXS)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Layout.verticalPadding)
        .accessibilityElement(children: .combine)
    }
}

private struct ConversationEmptyView: View {
    let viewModel: ConversationViewModel
    @Environment(\.colorScheme) private var colorScheme

    private typealias Layout = Constants.Conversation.Column.Empty

    var body: some View {
        if let name = viewModel.specialistName {
            VStack(spacing: Layout.contentSpacing) {
                Text(name)
                    .interFont(Constants.Typography.bodyM)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                if let description = viewModel.specialistDescription {
                    Text(description)
                        .interFont(Constants.Typography.bodyXS)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Layout.descriptionHorizontalPadding)
                }
                if let displayName = viewModel.currentModelDisplayName {
                    Text("Using \(displayName)")
                        .interFont(Constants.Typography.subtextXXS)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(Layout.modelCaptionOpacity))
                        .padding(.top, Layout.modelCaptionTopPadding)
                }
            }
        } else {
            Color.clear
        }
    }
}
