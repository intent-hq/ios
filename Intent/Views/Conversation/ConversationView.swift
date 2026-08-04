import Combine
import SwiftUI
import UIKit

// MARK: - ScrollView Momentum Helper

/// Stores a weak reference to the underlying UIScrollView so we can stop inertial scrolling.
class ScrollViewMomentumProxy: ObservableObject {
    weak var scrollView: UIScrollView?

    /// Kills any ongoing deceleration by setting contentOffset to its current value.
    func stopMomentum() {
        print("[SCROLL] stopMomentum called, scrollView=\(scrollView != nil)")
        guard let sv = scrollView else {
            print("[SCROLL] WARNING: scrollView is nil, cannot stop momentum")
            return
        }
        sv.setContentOffset(sv.contentOffset, animated: false)
        print("[SCROLL] Momentum stopped at offset \(sv.contentOffset)")
    }
}

/// A zero-size UIView that walks up the view hierarchy to find the enclosing UIScrollView.
struct ScrollViewFinder: UIViewRepresentable {
    let proxy: ScrollViewMomentumProxy

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.frame = .zero
        DispatchQueue.main.async {
            if let scrollView = Self.findScrollView(from: view) {
                proxy.scrollView = scrollView
                print("[SCROLL] Found UIScrollView: \(scrollView)")
            } else {
                print("[SCROLL] WARNING: Could not find UIScrollView in hierarchy")
            }
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    private static func findScrollView(from view: UIView) -> UIScrollView? {
        var current: UIView? = view
        while let parent = current?.superview {
            if let scrollView = parent as? UIScrollView {
                return scrollView
            }
            current = parent
        }
        return nil
    }
}

struct NoteSheetInfo: Identifiable {
    let id = UUID()
    let noteId: String
    let workspaceId: String
    let noteTitle: String
}

struct ConversationView: View {
    @StateObject private var viewModel: ConversationViewModel
    @StateObject private var scrollMomentumProxy = ScrollViewMomentumProxy()
    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.colorScheme) var colorScheme
    @State private var showModelPicker = false
    @State private var showDeleteConfirmation = false
    /// True while a deletion initiated from this view's own Delete button is in
    /// flight — the `agent:deleted` fallback must not double-navigate on top of
    /// the explicit dismiss().
    @State private var selfInitiatedDelete = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var scrollDebounceTask: Task<Void, Never>?
    @State private var presentedNote: NoteSheetInfo?
    @State private var childAgent: AgentDestination?
    @State private var userIsScrolledAway: Bool = false
    @State private var hasInitiallyScrolled: Bool = false
    @State private var isScrollingToBottom: Bool = false
    // Agent Q&A Ignore state — transient collapse of the question wizard to a
    // compact banner (never persisted; reset when a different set pends).
    @State private var questionWizardCollapsed = false
    @Environment(\.dismiss) private var dismiss

    init(agentId: String, workspaceId: String, agentName: String) {
        _viewModel = StateObject(wrappedValue: ConversationViewModel(
            agentId: agentId,
            workspaceId: workspaceId,
            agentName: agentName
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Pending attention request banner (kind-flavored, PROTOCOL §5.5).
            // Retires when the daemon clears the fields (agent next messaged).
            if let attention = viewModel.attentionRequest {
                AttentionRequestBanner(attention: attention)
                Divider()
            }

            // Main content area
            if viewModel.isLoading && viewModel.filteredMessages.isEmpty {
                loadingView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.filteredMessages.isEmpty {
                emptyView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                conversationContent
            }

            Divider()

            // Agent waiting indicator (above queued messages)
            if viewModel.store.isWaitingForAgents {
                VStack(spacing: 0) {
                    AgentWaitingView(
                        viewModel: viewModel,
                        onNavigateToAgent: { agentId, wsId, name in
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            childAgent = AgentDestination(agentId: agentId, workspaceId: wsId, agentName: name)
                        }
                    )
                    Divider()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Background hooks chip row (above queued messages, mirroring
            // the FE's above-the-input placement)
            if !viewModel.activeAgentHooks.isEmpty {
                VStack(spacing: 0) {
                    BackgroundHooksRow(viewModel: viewModel)
                    Divider()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Queued messages (above input)
            if !viewModel.queuedMessages.isEmpty {
                QueuedMessagesView(viewModel: viewModel)
                Divider()
            }

            // Agent Q&A: pending questions replace the composer with the
            // sequential wizard; Ignore collapses it to a banner and the
            // composer returns underneath. `.id` remounts (fresh wizard
            // state) per question-bearing message.
            if let pendingSet = viewModel.pendingQuestions {
                QuestionWizardView(
                    questions: pendingSet.questions,
                    collapsed: $questionWizardCollapsed,
                    onComplete: { answers in
                        Task { await viewModel.submitQuestionAnswers(answers) }
                    }
                )
                .id(pendingSet.messageId)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, questionWizardCollapsed ? 4 : 8)
            }

            // Message input (not rendered while the wizard is expanded —
            // Q&A replaces chat; the Ignore-collapsed banner restores it)
            if viewModel.pendingQuestions == nil || questionWizardCollapsed {
                MessageInputView(viewModel: viewModel)
            }
        }
        .onChange(of: viewModel.pendingQuestions?.messageId) { _, _ in
            // Ignore = collapse, not dismiss — reset whenever a different
            // question-bearing message pends (or the set resolves).
            questionWizardCollapsed = false
        }
        .background(Theme.background(for: colorScheme).ignoresSafeArea())
        .animation(.easeInOut(duration: 0.25), value: viewModel.store.isWaitingForAgents)
        .animation(.easeInOut(duration: 0.25), value: viewModel.activeAgentHooks.map(\.hookId))
        .navigationTitle(viewModel.agentName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.card(for: colorScheme), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let modelId = viewModel.currentModelId {
                        let displayName = viewModel.availableModels.first(where: { $0.id == modelId })?.name ?? modelId
                        Text("Model: \(displayName)")
                    }
                    if viewModel.filteredMessages.isEmpty {
                        Button {
                            showModelPicker = true
                        } label: {
                            Label("Change Model", systemImage: "cpu")
                        }
                    }
                    Button {
                        renameText = viewModel.agentName
                        showRenameAlert = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete Agent", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                }
            }
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerView(viewModel: viewModel)
        }
        .sheet(item: $presentedNote) { noteInfo in
            NavigationStack {
                NoteDetailView(
                    noteId: noteInfo.noteId,
                    workspaceId: noteInfo.workspaceId,
                    noteTitle: noteInfo.noteTitle
                )
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            presentedNote = nil
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete Agent?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                HapticManager.notification(.warning)
                selfInitiatedDelete = true
                Task {
                    do {
                        let _ = try await ConnectionManager.shared.request(
                            "agent.delete",
                            params: [
                                "agentId": viewModel.agentId,
                                "workspaceId": viewModel.workspaceId
                            ]
                        )
                        dismiss()
                    } catch {
                        selfInitiatedDelete = false
                        print("[ConversationView] Failed to delete agent: \(error)")
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete this agent and its conversation history.")
        }
        .alert("Rename Agent", isPresented: $showRenameAlert) {
            TextField("Agent name", text: $renameText)
            Button("Rename") {
                let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !newName.isEmpty else { return }
                Task {
                    do {
                        try await viewModel.renameAgent(newName)
                    } catch {
                        print("[ConversationView] Failed to rename agent: \(error)")
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .navigationDestination(item: $childAgent) { dest in
            ConversationView(
                agentId: dest.agentId,
                workspaceId: dest.workspaceId,
                agentName: dest.agentName
            )
            .id(dest.agentId)
        }
        .task {
            await viewModel.load()
            handleAgentNotFoundIfNeeded()
        }
        .onChange(of: viewModel.agentNotFound) { _, notFound in
            if notFound {
                handleAgentNotFoundIfNeeded()
            }
        }
        .onAppear {
            NotificationManager.shared.currentAgentId = viewModel.agentId
        }
        .onDisappear {
            NotificationManager.shared.currentAgentId = nil
            Task { await viewModel.teardownHooks() }
        }
    }

    /// Coordinator-driven fallback when the agent no longer exists (not-found at
    /// load or deleted while open): navigate back to the workspace's agent list.
    /// Skipped for a self-initiated delete (the Delete button already dismisses).
    private func handleAgentNotFoundIfNeeded() {
        guard viewModel.agentNotFound, !selfInitiatedDelete else { return }
        coordinator.handleMissingAgent(agentId: viewModel.agentId, workspaceId: viewModel.workspaceId)
    }

    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading conversation...")
                .font(.subheadline)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
    }

    @ViewBuilder
    private var emptyView: some View {
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

    @ViewBuilder
    private var conversationContent: some View {
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        // Scroll anchor at the top (visually the bottom due to flip)
                        Color.clear.frame(height: 8)
                            .flippedUpsideDown()
                            .background(ScrollViewFinder(proxy: scrollMomentumProxy))
                            .id("scroll-bottom")

                        // Thinking indicator (visually at bottom due to flip)
                        if viewModel.isStreaming {
                            thinkingIndicatorView
                                .transition(.move(edge: .top).combined(with: .opacity))
                                .flippedUpsideDown()
                                .id("thinking-indicator")
                        }

                        // Suggested prompts (visually above newest message due to flip)
                        if !viewModel.suggestedPrompts.isEmpty && !viewModel.isStreaming {
                            suggestedPromptsView
                                .flippedUpsideDown()
                                .id("suggested-prompts")
                        }

                        // Messages in reverse order (newest first, which appears at bottom due to flip)
                        ForEach(viewModel.filteredMessages.reversed()) { message in
                            MessageView(
                                message: message,
                                workspaceId: viewModel.workspaceId,
                                onNavigateToNote: { noteId, wsId, title in
                                    presentedNote = NoteSheetInfo(noteId: noteId, workspaceId: wsId, noteTitle: title)
                                }
                            )

                                .flippedUpsideDown()
                                .id(message.id)
                        }

                        // Truncation banner (appears at the top/oldest end due to flip)
                        if viewModel.isTruncated {
                            truncationBanner
                                .flippedUpsideDown()
                                .id("truncation-banner")
                        }
                    }

                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                .flippedUpsideDown()
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.always)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                    }
                )
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    // In the flipped view, "at bottom" means native scroll is at top (contentOffset.y ≈ 0)
                    let atBottom = geometry.contentOffset.y <= 50
                    print("[SCROLL] contentOffset.y=\(geometry.contentOffset.y), contentSize=\(geometry.contentSize.height), containerSize=\(geometry.containerSize.height), atBottom=\(atBottom)")
                    return !atBottom
                } action: { _, isScrolledAway in
                    print("[SCROLL] isScrolledAway=\(isScrolledAway), hasInitiallyScrolled=\(hasInitiallyScrolled), isScrollingToBottom=\(isScrollingToBottom)")
                    if hasInitiallyScrolled && !isScrollingToBottom {
                        userIsScrolledAway = isScrolledAway
                    }
                }
                .onChange(of: viewModel.filteredMessages.count) { oldCount, newCount in
                    if newCount > oldCount,
                       let lastMessage = viewModel.filteredMessages.last,
                       lastMessage.role == .user {
                        // User sent a message — reset scroll state
                        userIsScrolledAway = false
                    }
                    if !userIsScrolledAway {
                        scrollToBottom(proxy: proxy)
                    }
                }
                .onChange(of: viewModel.isStreaming) { _, _ in
                    if !userIsScrolledAway {
                        scrollToBottom(proxy: proxy)
                    }
                }
                .onChange(of: viewModel.store.streamingUpdateCount) { _, _ in
                    if !userIsScrolledAway {
                        scrollToBottom(proxy: proxy)
                    }
                }
                .onChange(of: viewModel.queuedMessages.count) { _, _ in
                    if !userIsScrolledAway {
                        scrollToBottom(proxy: proxy)
                    }
                }
                .onChange(of: viewModel.store.isWaitingForAgents) { _, _ in
                    if !userIsScrolledAway {
                        scrollToBottom(proxy: proxy)
                    }
                }
                .onChange(of: viewModel.isLoading) { _, isLoading in
                    if !isLoading {
                        // Small delay to let LazyVStack finish layout
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            scrollToBottom(proxy: proxy, animated: false)
                            // Mark initial scroll as complete so scroll tracking can begin
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                hasInitiallyScrolled = true
                            }
                        }
                    }
                }
                .onAppear {
                    // Fallback: if isLoading was already false when the view appeared
                    // (e.g., cached data), the onChange above never fires.
                    // Ensure hasInitiallyScrolled gets set after a short delay.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if !hasInitiallyScrolled {
                            hasInitiallyScrolled = true
                        }
                    }
                }
                .onChange(of: userIsScrolledAway) { _, scrolledAway in
                    if !scrolledAway {
                        scrollToBottom(proxy: proxy)
                    }
                }
            }

            // "Go to End" floating pill button
            if userIsScrolledAway {
                Button {
                    scrollMomentumProxy.stopMomentum()
                    isScrollingToBottom = true
                    userIsScrolledAway = false
                    // The onChange(of: userIsScrolledAway) will call scrollToBottom
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                        Text("Go to End")
                            .font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(.easeInOut(duration: 0.2), value: userIsScrolledAway)
            }
        }
    }

    @ViewBuilder
    private var thinkingIndicatorView: some View {
        HStack(spacing: 6) {
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)
            Text("Thinking...")
                .font(.caption)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var suggestedPromptsView: some View {
        VStack(spacing: 8) {
            ForEach(viewModel.suggestedPrompts, id: \.self) { prompt in
                Button {
                    Task { await viewModel.sendSuggestedPrompt(prompt) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "paperplane")
                            .font(.caption)
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        Text(prompt)
                            .font(.subheadline)
                            .foregroundStyle(Theme.foreground(for: colorScheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.muted(for: colorScheme).opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Theme.border(for: colorScheme).opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var truncationBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.footnote)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            Text("Showing the most recent \(viewModel.filteredMessages.count) of \(viewModel.totalMessageCount) messages.\nSee the full conversation on the desktop app.")
                .font(.footnote)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Theme.muted(for: colorScheme).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        scrollDebounceTask?.cancel()
        scrollDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms debounce
            guard !Task.isCancelled else { return }
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("scroll-bottom", anchor: .top)
                }
            } else {
                proxy.scrollTo("scroll-bottom", anchor: .top)
            }
            // Clear the scrolling flag after animation settles
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms for animation to complete
            guard !Task.isCancelled else { return }
            isScrollingToBottom = false
        }
    }
}

// MARK: - Attention Request Banner

/// Kind-flavored conversation-header banner for a pending attention request.
struct AttentionRequestBanner: View {
    let attention: PendingAttentionRequest
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: attention.kind.systemImage)
                .font(.subheadline)
                .foregroundStyle(attention.kind.color)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(attention.kind.label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.foreground(for: colorScheme))

                    if let raisedAt = attention.raisedAt {
                        // Clamp to now: a slightly-ahead device clock would
                        // otherwise render a live countdown before " ago".
                        (Text(min(raisedAt, Date()), style: .relative) + Text(" ago"))
                            .font(.caption)
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    }
                }

                if let reason = attention.reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(attention.kind.color.opacity(0.1))
    }
}

// MARK: - Inverted Scroll Modifier

struct FlippedUpsideDown: ViewModifier {
    func body(content: Content) -> some View {
        content
            .rotationEffect(.radians(Double.pi))
            .scaleEffect(x: -1, y: 1, anchor: .center)
    }
}

extension View {
    func flippedUpsideDown() -> some View {
        modifier(FlippedUpsideDown())
    }
}


