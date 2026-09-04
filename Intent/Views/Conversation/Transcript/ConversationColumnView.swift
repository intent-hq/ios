import SwiftUI

struct ConversationColumnView: View {
    let viewModel: ConversationViewModel
    let onNavigateToNote: (String, String, String) -> Void
    let onNavigateToAgent: (String, String, String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var questionWizardCollapsed = false
    @State private var conversationHeight: CGFloat = 0
    @State private var transcriptScrollState = ConversationTranscriptScrollState()

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
        .onChange(of: viewModel.pendingQuestions?.messageId) { _, _ in
            questionWizardCollapsed = false
        }
        .background(Theme.background(for: colorScheme).ignoresSafeArea())
        .animation(
            .easeInOut(duration: Constants.Conversation.Column.chromeAnimationDuration),
            value: viewModel.store.isWaitingForAgents)
        .animation(
            .easeInOut(duration: Constants.Conversation.Column.chromeAnimationDuration),
            value: viewModel.activeAgentHooks.map(\.hookId))
        .animation(
            .easeInOut(duration: Constants.Conversation.Column.chromeAnimationDuration),
            value: viewModel.activeAgentMonitors.map(\.monitorId))
    }

    @ViewBuilder
    private var columnContent: some View {
        if let attention = viewModel.attentionRequest {
            AttentionRequestBanner(attention: attention)
            Divider()
        }

        if viewModel.isLoading && viewModel.filteredMessages.isEmpty {
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
            QuestionWizardView(
                questions: pendingSet.questions,
                collapsed: $questionWizardCollapsed,
                containerHeight: conversationHeight,
                onComplete: { answers in
                    let answeredId = pendingSet.messageId
                    Task {
                        await viewModel.submitQuestionAnswers(
                            answers, answeredQuestionsMessageId: answeredId)
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
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, questionWizardCollapsed ? 4 : 8)
        }

        if viewModel.pendingQuestions == nil || questionWizardCollapsed {
            MessageInputView(viewModel: viewModel, store: viewModel.store)
        }
    }
}

private struct ConversationLoadingView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 12) {
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

    var body: some View {
        if let name = viewModel.specialistName {
            VStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                Text(name)
                    .font(.headline)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                if let description = viewModel.specialistDescription {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                if let modelId = viewModel.currentModelId {
                    let displayName = viewModel.availableModels.first(where: { $0.id == modelId })?.name ?? modelId
                    Text("Using \(displayName)")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(0.7))
                        .padding(.top, 4)
                }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                Text("No messages yet")
                    .font(.headline)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                Text("Messages will appear here as the agent works.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                if let modelId = viewModel.currentModelId {
                    let displayName = viewModel.availableModels.first(where: { $0.id == modelId })?.name ?? modelId
                    Text("Using \(displayName)")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(0.7))
                        .padding(.top, 4)
                }
            }
        }
    }
}