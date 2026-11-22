import SwiftUI

struct ConversationColumnView: View {
    let viewModel: ConversationViewModel
    let onNavigateToNote: (String, String, String) -> Void
    let onNavigateToAgent: (String, String, String) -> Void
    var usesWorkspaceDesign = false
    @Binding var answeringWorkspaceQuestions: Bool
    var onDemoCover: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.conversationPresentation) private var presentation
    @Environment(\.workspaceUsesVerticalBar) private var usesVerticalBar
    @State private var questionWizardCollapsed = false
    @State private var submittingQuestions: PendingQuestionSet?
    @State private var conversationHeight: CGFloat = 0
    @State private var questionInputTop: CGFloat?
    @State private var composerInputTop: CGFloat?
    @State private var accessoryRowsTop: CGFloat?
    @State private var composerFocused = false
    @State private var keyboardVisible = false
    @State private var transcriptScrollState = ConversationTranscriptScrollState()

    private typealias Layout = Constants.Conversation.Column
    private typealias Design = Constants.Conversation.Design

    #if os(visionOS)
    @State private var questionSheetPresented = false
    #endif

    var body: some View {
        VStack(spacing: 0) { columnContent }
        .ignoresSafeArea(.container, edges: usesWorkspaceDesign && presentation != .iPad && usesVerticalBar && !keyboardVisible ? .bottom : [])
        .environment(\.conversationComposerFocus, $composerFocused)
        .modifier(QuestionAttachmentLifecycle(viewModel: viewModel))
        .modifier(IPadTypingFocus(isFocused: $composerFocused, composerVisible: composerVisible))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { conversationHeight = $0 }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        .onChange(of: viewModel.pendingQuestions?.messageId) { _, newId in
            AppLog.userInterface.debug("[SCROLL][QUESTION] pending changed present=\(newId != nil) keyboardVisible=\(keyboardVisible) columnHeight=\(conversationHeight)")
            questionWizardCollapsed = false
            #if os(visionOS)
            if submittingQuestions == nil { questionSheetPresented = newId != nil }
            #endif
        }
        .onChange(of: viewModel.filteredMessageIDs, initial: true) { _, messageIDs in
            transcriptScrollState.rowHeightCache.retainMessages(withIDs: messageIDs)
            transcriptScrollState.disclosures.retainMessages(withIDs: messageIDs)
            transcriptScrollState.retainViewportMessages(withIDs: messageIDs)
        }
        #if os(visionOS)
        .onAppear {
            questionSheetPresented = viewModel.pendingQuestions != nil
        }
        .modifier(FloatingComposerOrnament(
            showsLoadingState: viewModel.showsLoadingState,
            composerVisible: composerVisible,
            onWithdraw: viewModel.cancelPhotoImport
        ) {
            MessageInputView(
                viewModel: viewModel,
                store: viewModel.store,
                allowsSending: composerVisible
            )
            .environment(\.conversationComposerFocus, $composerFocused)
        })
        .sheet(isPresented: $questionSheetPresented) {
            questionSheet
                .coversConversationComposers()
        }
        #endif
        .animation(.easeInOut(duration: Layout.Loading.fadeDuration), value: viewModel.showsLoadingState)
        .animation(
            .easeInOut(duration: Constants.Conversation.Column.chromeAnimationDuration),
            value: viewModel.store.isWaitingForAgents
        )
        .animation(
            .easeInOut(duration: Constants.Conversation.Column.chromeAnimationDuration),
            value: viewModel.conversationGoal
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
        #if DEBUG
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
        #endif
        ZStack {
            if viewModel.showsLoadingState {
                ConversationConnectionLoadingView(viewModel: viewModel, usesWorkspaceDesign: usesWorkspaceDesign)
                    .availableWhenReconnected(isMissing: true)
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
                    #if os(visionOS)
                    ConversationHeaderBackdrop()
                    #else
                    if usesWorkspaceDesign { WorkspaceHeaderFade() }
                    #endif
                }
            }
        }
        .animation(.easeInOut(duration: Layout.Loading.fadeDuration), value: viewModel.showsLoadingState)
        measuredAccessoryRows

        questionRegion
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { questionInputTop = $0 }
            .preference(
                key: WorkspaceActionMenuInputTop.self,
                value: FloatingComposerPolicy.questionRegionLauncherTop(
                    host: composerHost,
                    questionInputTop: questionInputTop,
                    hasQuestionContent: viewModel.pendingQuestions != nil || viewModel.isPendingQuestionRecoveryLoading,
                    composerVisible: composerVisible,
                    usesPhoneQuestionPresentation: usesPhoneQuestionPresentation,
                    accessoryRowsTop: accessoryRowsLauncherTop
                )
            )
            .layoutPriority(usesPhoneQuestionPresentation ? 1 : 0)
        if composerHost == .inline, !viewModel.showsLoadingState, composerVisible || usesPhoneQuestionPresentation {
            VStack(spacing: 0) {
                if usesWorkspaceDesign, viewModel.showsWorkspaceStatusPills {
                    WorkspaceStatusPillsRow(viewModel: viewModel)
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
                    )
                    .padding(.horizontal, usesWorkspaceDesign ? stickyHorizontalInset : 0)
                    .padding(.top, usesWorkspaceDesign && !workspaceQueueVisible ? Design.Composer.keyboardBottomSpacing : 0)
                    .padding(.bottom, usesWorkspaceDesign ? composerBottomInset : 0)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { composerInputTop = $0 }
            .keepsReadOnlyPillAbove()
            .preference(key: WorkspaceActionMenuInputTop.self, value: composerInputTop)
        }
    }

    @ViewBuilder
    private var questionRegion: some View {
        if let pendingSet = viewModel.pendingQuestions ?? submittingQuestions {
            #if os(visionOS)
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
            if usesPhoneQuestionPresentation {
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
                    attachments: viewModel.questionAttachments(for: pendingSet.messageId),
                    workspaceId: viewModel.workspaceId,
                    containerHeight: conversationHeight,
                    isSubmitting: submittingQuestions != nil,
                    onComplete: { answers in
                        submit(answers, pending: pendingSet)
                    },
                    onDismiss: {
                        let dismissedId = pendingSet.messageId
                        Task {
                            await viewModel.dismissQuestions(messageId: dismissedId)
                        }
                    }
                )
                .id(pendingSet.messageId)
                .padding(.horizontal, presentation == .iPad ? 0 : Layout.questionWizardHorizontalPadding)
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

        if viewModel.isPendingQuestionRecoveryLoading, !questionWizardCollapsed {
            PendingQuestionRecoveryPlaceholder()
        }
    }

    private var composerVisible: Bool {
        #if os(visionOS)
        return !viewModel.isPendingQuestionRecoveryLoading || questionWizardCollapsed
        #else
        return (viewModel.pendingQuestions == nil && !viewModel.isPendingQuestionRecoveryLoading)
            || questionWizardCollapsed
        #endif
    }

    private var composerHost: ComposerHost {
        #if os(visionOS)
        ComposerHost.forPlatform(isVisionOS: true)
        #else
        ComposerHost.forPlatform(isVisionOS: false)
        #endif
    }

    #if os(visionOS)
    @ViewBuilder
    private var questionSheet: some View {
        if let pendingSet = viewModel.pendingQuestions ?? submittingQuestions {
            QuestionWizardView(
                questions: pendingSet.questions,
                collapsed: Binding(
                    get: { false },
                    set: { if $0 { questionSheetPresented = false } }
                ),
                attachments: viewModel.questionAttachments(for: pendingSet.messageId),
                workspaceId: viewModel.workspaceId,
                isSubmitting: submittingQuestions != nil,
                onComplete: { answers in
                    submit(answers, pending: pendingSet)
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

    private func submit(_ answers: [QuestionAnswer], pending: PendingQuestionSet) {
        guard submittingQuestions == nil else { return }
        submittingQuestions = pending
        Task { await send(answers, messageId: pending.messageId) }
    }
}

extension ConversationColumnView {
    private func send(_ answers: [QuestionAnswer], messageId: String) async {
        await viewModel.submitQuestionAnswers(answers, answeredQuestionsMessageId: messageId)
        submittingQuestions = nil
        #if os(visionOS)
        questionSheetPresented = viewModel.pendingQuestions != nil
        #endif
    }

    private var workspaceQueueVisible: Bool {
        usesWorkspaceDesign && !viewModel.queuedMessages.isEmpty
    }

    private var stickyHorizontalInset: CGFloat {
        guard presentation != .iPad else { return 0 }
        return keyboardVisible || composerFocused ? Design.Composer.keyboardHorizontalInset : Design.horizontalInset
    }

    private var composerBottomInset: CGFloat {
        if presentation != .iPad, usesVerticalBar, !keyboardVisible { return Design.Composer.verticalBarBottomSpacing }
        return presentation == .iPad && !keyboardVisible ? Design.IPad.composerBottomInset : Design.Composer.keyboardBottomSpacing
    }

    private var usesPhoneQuestionPresentation: Bool {
        usesWorkspaceDesign && presentation != .iPad
    }

    private var hasAccessoryRows: Bool {
        let showsMonitors = !usesWorkspaceDesign && !viewModel.showsLoadingState
            && (!viewModel.activeAgentMonitors.isEmpty || viewModel.monitoredPrStore.error != nil)
        let showsHooks = !viewModel.activeAgentHooks.isEmpty || viewModel.hookStore.error != nil
        let showsQueue = !usesWorkspaceDesign && !viewModel.queuedMessages.isEmpty
        let showsScripts = !usesWorkspaceDesign && viewModel.showsScriptMonitorStatus
        return viewModel.store.isWaitingForAgents || showsMonitors || showsHooks || showsQueue || showsScripts
    }

    private var accessoryRowsLauncherTop: CGFloat? {
        hasAccessoryRows ? accessoryRowsTop : nil
    }

    private var measuredAccessoryRows: some View {
        VStack(spacing: 0) {
            accessoryRows
        }
        .keepsReadOnlyPillAbove()
        #if os(visionOS)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { accessoryRowsTop = $0 }
        #endif
    }

    @ViewBuilder
    private var accessoryRows: some View {
        if !usesWorkspaceDesign, !viewModel.showsLoadingState { Divider() }

        MonitoredScriptsRow(viewModel: viewModel, showsRow: !usesWorkspaceDesign)
        if !usesWorkspaceDesign, !viewModel.showsLoadingState, let goal = viewModel.conversationGoal {
            ConversationGoalPill(
                goal: goal,
                onSave: { await viewModel.saveGoal($0) },
                onRemove: { await viewModel.removeGoal() }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Design.horizontalInset)
            .padding(.vertical, Design.Status.composerSpacing)
        }
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

        if presentation == .iPad, !composerVisible, !viewModel.showsLoadingState {
            if viewModel.showsWorkspaceStatusPills {
                WorkspaceStatusPillsRow(viewModel: viewModel)
                    .padding(.vertical, Design.Status.composerSpacing)
            }
            if workspaceQueueVisible {
                WorkspaceQueuedMessagesView(viewModel: viewModel)
                    .padding(.vertical, Design.Queue.composerSpacing)
            }
        }
    }
}

private struct ConversationConnectionLoadingView: View {
    let viewModel: ConversationViewModel
    let usesWorkspaceDesign: Bool
    @Environment(\.conversationPresentation) private var presentation

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
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, Constants.Conversation.Transcript.transcriptTopPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var horizontalInset: CGFloat {
        if presentation == .iPad { return 0 }
        return usesWorkspaceDesign ? Constants.Conversation.Design.horizontalInset : Constants.Conversation.Transcript.transcriptHorizontalPadding
    }
}

struct ConversationBackground: View {
    let isLoading: Bool
    let usesWorkspaceDesign: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.conversationBackgroundColor) private var backgroundColor

    var body: some View {
        (backgroundColor ?? (usesWorkspaceDesign ? Constants.Conversation.Design.Palette.background(for: colorScheme) : Theme.background(for: colorScheme)))
            .ignoresSafeArea()
    }
}

#if os(visionOS)
private struct ConversationHeaderBackdrop: View {
    private static let fadeHeight: CGFloat = 24
    @State private var barHeight: CGFloat = 0

    var body: some View {
        let height = barHeight + Self.fadeHeight
        Rectangle()
            .fill(.regularMaterial)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: barHeight / height),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(height: height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { barHeight = $0 }
            .ignoresSafeArea(.container, edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
#endif

private struct PendingQuestionRecoveryPlaceholder: View {
    @Environment(\.colorScheme) private var colorScheme

    private typealias Layout = Constants.Conversation.Column.PendingQuestionRecovery

    var body: some View {
        HStack(spacing: Layout.contentSpacing) {
            ProgressView()
                .controlSize(.small)
            Text("Loading questions…")
                .interFont(Constants.Typography.bodyXS)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Layout.verticalPadding)
        .accessibilityElement(children: .combine)
    }
}
