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
    /// One-shot latch for the entry scroll: set synchronously when the scroll
    /// is scheduled (hasInitiallyScrolled flips only after the async delays,
    /// so it alone can't dedupe near-simultaneous triggers).
    @State private var initialScrollScheduled: Bool = false
    @State private var isScrollingToBottom: Bool = false
    // Agent Q&A Ignore state — transient collapse of the question wizard to a
    // compact banner (never persisted; reset when a different set pends).
    @State private var questionWizardCollapsed = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(agentId: String, workspaceId: String, agentName: String) {
        _viewModel = StateObject(wrappedValue: ConversationViewModel(
            agentId: agentId,
            workspaceId: workspaceId,
            agentName: agentName
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            columnContent
        }
        .onChange(of: viewModel.pendingQuestions?.messageId) { _, _ in
            // Ignore = collapse, not dismiss — reset whenever a different
            // question-bearing message pends (or the set resolves).
            questionWizardCollapsed = false
        }
        .background(Theme.background(for: colorScheme).ignoresSafeArea())
        .animation(.easeInOut(duration: 0.25), value: viewModel.store.isWaitingForAgents)
        .animation(.easeInOut(duration: 0.25), value: viewModel.activeAgentHooks.map(\.hookId))
        .animation(.easeInOut(duration: 0.25), value: viewModel.activeAgentMonitors.map(\.monitorId))
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
        // Non-destructive dismiss-failure surface (intent-hq/monorepo#1800):
        // nothing was dismissed — the wizard re-pends via the store's marker
        // rollback; this alert just makes the failure explicit. `presenting:`
        // hands the closures a captured non-optional detail so the message
        // doesn't degrade mid-dismissal (same shape as ConnectionsView).
        .alert(
            "Couldn't Dismiss Questions",
            isPresented: Binding(
                get: { viewModel.dismissQuestionsError != nil },
                set: { if !$0 { viewModel.dismissQuestionsError = nil } }),
            presenting: viewModel.dismissQuestionsError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { detail in
            Text("The questions were not dismissed and are still pending. " + detail)
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
            // Entry itself never marks seen (the divider anchor must survive
            // until the user leaves or the turn finishes).
            viewModel.conversationAppeared()
        }
        .onDisappear {
            NotificationManager.shared.currentAgentId = nil
            Task { await viewModel.teardownLiveStores() }
            // Stop-looking boundary — fires markSeen immediately.
            viewModel.conversationDisappeared()
        }
        .onChange(of: scenePhase) { _, phase in
            viewModel.scenePhaseChanged(isActive: phase == .active)
        }
    }

    /// Coordinator-driven fallback when the agent no longer exists (not-found at
    /// load or deleted while open): navigate back to the workspace's agent list.
    /// Skipped for a self-initiated delete (the Delete button already dismisses).
    private func handleAgentNotFoundIfNeeded() {
        guard viewModel.agentNotFound, !selfInitiatedDelete else { return }
        coordinator.handleMissingAgent(agentId: viewModel.agentId, workspaceId: viewModel.workspaceId)
    }

    /// The main column's children (attention banner, transcript, chip rows,
    /// composer). Extracted from `body` so the type checker sees smaller
    /// expressions instead of one monolithic body (the divider integration
    /// pushed the single-expression body past its type-check budget).
    @ViewBuilder
    private var columnContent: some View {
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

        // Monitored PRs chip row (above the hooks row, mirroring the
        // FE's ordering)
        if !viewModel.activeAgentMonitors.isEmpty {
            VStack(spacing: 0) {
                MonitoredPrsRow(viewModel: viewModel)
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
                    // Mount-time capture: this wizard is `.id`-keyed on
                    // pendingSet.messageId, so this id is by construction
                    // the set the user answered — never re-derived after
                    // the Task hop, where a derivation flip could
                    // otherwise send the answer untagged (#1789).
                    let answeredId = pendingSet.messageId
                    Task {
                        await viewModel.submitQuestionAnswers(
                            answers, answeredQuestionsMessageId: answeredId)
                    }
                },
                onDismiss: {
                    // Same mount-time capture discipline as onComplete.
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

        // Message input (not rendered while the wizard is expanded —
        // Q&A replaces chat; the Ignore-collapsed banner restores it)
        if viewModel.pendingQuestions == nil || questionWizardCollapsed {
            MessageInputView(viewModel: viewModel)
        }
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
        // Hoisted out of the ForEach: the latched anchor id is recomputed on
        // every row otherwise (O(n²) per render pass), and the local also
        // shrinks the row expression the type checker has to solve.
        let dividerAnchorId = viewModel.newMessagesDividerAnchorId
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
                            // "New messages" divider: belongs visually BELOW
                            // the anchor row (between the anchor and the first
                            // unseen message). LazyVStack code order runs
                            // visual bottom→top in the flipped list, so
                            // emitting the divider BEFORE the anchor's
                            // MessageView places it on the newer side.
                            if message.id == dividerAnchorId {
                                NewMessagesDividerView()
                                    .flippedUpsideDown()
                                    .id("new-messages-divider")
                            }
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
                // The follow-to-bottom handlers below are gated on
                // hasInitiallyScrolled (flips ~0.3s after the entry scroll):
                // until the entry-scroll follow decision has been made,
                // userIsScrolledAway is still false, so a stream tick or row
                // arrival in that window would otherwise yank the viewport
                // off the divider and read the bottom clamp as "follow stays
                // enabled".
                .onChange(of: viewModel.filteredMessages.count) { oldCount, newCount in
                    if newCount > oldCount,
                       let lastMessage = viewModel.filteredMessages.last,
                       lastMessage.role == .user {
                        // User sent a message — reset scroll state
                        userIsScrolledAway = false
                    }
                    if hasInitiallyScrolled && !userIsScrolledAway {
                        scrollToBottom(proxy: proxy)
                    }
                }
                .onChange(of: viewModel.isStreaming) { _, _ in
                    if hasInitiallyScrolled && !userIsScrolledAway {
                        scrollToBottom(proxy: proxy)
                    }
                }
                .onChange(of: viewModel.store.streamingUpdateCount) { _, _ in
                    if hasInitiallyScrolled && !userIsScrolledAway {
                        scrollToBottom(proxy: proxy)
                    }
                }
                .onChange(of: viewModel.queuedMessages.count) { _, _ in
                    if hasInitiallyScrolled && !userIsScrolledAway {
                        scrollToBottom(proxy: proxy)
                    }
                }
                .onChange(of: viewModel.store.isWaitingForAgents) { _, _ in
                    if hasInitiallyScrolled && !userIsScrolledAway {
                        scrollToBottom(proxy: proxy)
                    }
                }
                .onChange(of: viewModel.isLoading) { _, isLoading in
                    if !isLoading {
                        runInitialScrollIfNeeded(proxy: proxy)
                    }
                }
                .onAppear {
                    // On first open the transcript mounts only after the load
                    // settles (the loading placeholder renders while
                    // isLoading is true), so the onChange above never sees the
                    // true→false transition — run the entry scroll from here
                    // when the load has already settled. Also covers cached
                    // data where isLoading never flips.
                    if !viewModel.isLoading {
                        runInitialScrollIfNeeded(proxy: proxy)
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

    /// Initial landing position on conversation entry.
    ///
    /// Without a latched "New messages" divider this is byte-identical to
    /// today: an unanimated scroll to the bottom. With a divider, entry
    /// targets the divider row instead and never enables follow-to-bottom
    /// on its own. Pragmatic approximation of the FE's
    /// `dividerVisibleWhenScrolledToBottom` decision (documented choice):
    /// we always scroll to the divider id with `anchor: .bottom` — in the
    /// flipped list the layout bottom is the visual top, so this pins the
    /// divider near the top of the screen; when the whole unseen tail fits
    /// on one screen the scroll clamps at contentOffset ≈ 0, which IS the
    /// visual bottom, i.e. today's scroll-to-bottom. Follow-to-bottom is
    /// then disabled only when the clamp did not occur (we actually landed
    /// away from the bottom), read from the UIScrollView captured by
    /// ScrollViewFinder. If the divider row cannot be resolved (anchor row
    /// filtered out or not materialized by the LazyVStack), `scrollTo` is a
    /// no-op and the fresh scroll view stays at the bottom — the documented
    /// fallback to bottom-scroll.
    ///
    /// `runInitialScrollIfNeeded` runs this exactly once per view lifetime,
    /// from whichever trigger fires first — the transcript's onAppear (first
    /// open: the transcript mounts only after the load settles) or
    /// onChange(of: isLoading) (reloads while the transcript is already
    /// mounted).
    private func runInitialScrollIfNeeded(proxy: ScrollViewProxy) {
        guard !initialScrollScheduled else { return }
        initialScrollScheduled = true
        // Small delay to let LazyVStack finish layout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            performInitialScroll(proxy: proxy)
            // Mark initial scroll as complete so scroll tracking can begin
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                hasInitiallyScrolled = true
            }
        }
    }

    private func performInitialScroll(proxy: ScrollViewProxy) {
        guard viewModel.newMessagesDividerAnchorId != nil else {
            scrollToBottom(proxy: proxy, animated: false)
            return
        }
        proxy.scrollTo("new-messages-divider", anchor: .bottom)
        // Let the scroll settle before deciding follow state; runs before
        // hasInitiallyScrolled flips (+0.2s), so the geometry handler cannot
        // race this write.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let offsetY = scrollMomentumProxy.scrollView?.contentOffset.y ?? 0
            if NewMessagesDivider.followDisabledAfterEntryScroll(flippedContentOffsetY: offsetY) {
                userIsScrolledAway = true
            }
        }
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


