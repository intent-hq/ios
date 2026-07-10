import SwiftUI

enum GestureDirection {
    case horizontal, vertical
}

struct CoverflowContainerView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @ObservedObject var store = CoverflowStore.shared
    @Environment(\.colorScheme) var colorScheme

    @State private var badgeBounce = false
    @State private var dismissingAgentId: String?
    @State private var isExposeMode = false
    @State private var dragOffset: CGFloat = 0
    @State private var gestureDirection: GestureDirection? = nil
    @State private var conversationOpacity: Double = 1.0
    @State private var isTransitioning = false
    @State private var exposeScrollOffset: CGFloat = 0
    @State private var exposeScrollDragOffset: CGFloat = 0
    @State private var keyboardHeight: CGFloat = 0

    private let hapticSnap = UIImpactFeedbackGenerator(style: .medium)
    private let hapticFinish = UINotificationFeedbackGenerator()

    /// All agents in the queue — dismiss moves to end, banish removes entirely.
    private var visibleAgents: [CoverflowAgent] {
        store.queue
    }

    /// Current index derived from store.focusedAgentId
    private var currentIndex: Int {
        guard let focusedId = store.focusedAgentId,
              let idx = visibleAgents.firstIndex(where: { $0.id == focusedId }) else {
            return 0
        }
        return idx
    }

    /// The currently focused agent
    private var focusedAgent: CoverflowAgent? {
        if let focusedId = store.focusedAgentId {
            return visibleAgents.first { $0.id == focusedId }
        }
        return visibleAgents.first
    }

    var body: some View {
        ZStack {
            // Animated activity background
            CoverflowBackgroundView(
                store: store,
                isTransitioning: isTransitioning
            )

            if visibleAgents.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    unifiedCardLayout

                    // Page dots and action buttons (hidden when keyboard visible)
                    if keyboardHeight == 0 {
                        if !isExposeMode {
                            pageIndicatorDots
                            coverflowActionButtons
                        } else {
                            exposeActionButtons
                        }
                    }
                }
            }

            // Close button — top right
            closeButton

            // Finished badge — top left (hidden when keyboard visible)
            if keyboardHeight == 0 {
                finishedBadge
            }

            // Disconnection overlay — highest Z-level inside fullScreenCover
            if coordinator.isDisconnected {
                Color.black.opacity(0.7)
                    .ignoresSafeArea()
                    .overlay {
                        VStack(spacing: 12) {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(1.2)
                            Text("Reconnecting…")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text("Connection to your computer was lost.")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea(.keyboard)
        .onAppear {
            // Initialize focus to first agent if not set
            if store.focusedAgentId == nil, let first = visibleAgents.first {
                store.focusedAgentId = first.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                withAnimation(.easeOut(duration: 0.25)) {
                    keyboardHeight = frame.height
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.25)) {
                keyboardHeight = 0
            }
        }
        .onChange(of: store.unreviewedAgentIds.count) { oldCount, newCount in
            if newCount > oldCount {
                // DO NOT auto-scroll — keep user's current card stable
                // Just notify with haptic and badge bounce
                hapticFinish.notificationOccurred(.success)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.4)) {
                    badgeBounce = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    badgeBounce = false
                }
            }
        }

    }

    // MARK: - Unified Card Layout (all cards always rendered, positions animated)

    @ViewBuilder
    private var unifiedCardLayout: some View {
        GeometryReader { geo in
            let screenW = geo.size.width
            let screenH = geo.size.height

            // Exposé grid parameters
            let gridCols = 3
            let gridHPad: CGFloat = 48
            let gridSpacing: CGFloat = 32
            let gridTopPad: CGFloat = 80
            let gridCellW = (screenW - gridHPad * 2 - gridSpacing * CGFloat(gridCols - 1)) / CGFloat(gridCols)
            let gridCellH: CGFloat = 300

            // Coverflow parameters
            let cardW = screenW - 120
            let cardH = max(screenH - 120 - keyboardHeight, 200)

            ForEach(Array(visibleAgents.enumerated()), id: \.element.id) { index, agent in
                let isFocused = agent.id == store.focusedAgentId
                let focusedIdx = currentIndex

                // Grid position
                let gridRow = index / gridCols
                let gridCol = index % gridCols
                let gridX = gridHPad + CGFloat(gridCol) * (gridCellW + gridSpacing) + gridCellW / 2
                let scrollY = exposeScrollOffset + exposeScrollDragOffset
                let gridY = gridTopPad + CGFloat(gridRow) * (gridCellH + gridSpacing) + gridCellH / 2 + scrollY

                // Coverflow position — dragOffset shifts all cards together during swipe
                let distFromFocused = CGFloat(index - focusedIdx)
                let coverX = screenW / 2 + distFromFocused * (cardW + 120) + dragOffset
                let coverY: CGFloat = 85 + cardH / 2

                // Interpolate based on mode
                let x = isExposeMode ? gridX : coverX
                let y = isExposeMode ? gridY : coverY
                let w = isExposeMode ? gridCellW : cardW
                let h = isExposeMode ? gridCellH : cardH

                // Dismiss animation
                let isDismissing = dismissingAgentId == agent.id
                let dismissScale: CGFloat = isDismissing ? 0.8 : 1.0
                let dismissOffsetX: CGFloat = isDismissing ? screenW * 0.6 : 0
                let dismissOpacity: Double = isDismissing ? 0 : cardOpacity(index: index, focusedIndex: focusedIdx)

                let showContent: Bool = {
                    if isTransitioning {
                        return false  // Remove ALL ConversationViews during animation
                    }
                    if isExposeMode {
                        return true
                    } else {
                        let dist = abs(index - focusedIdx)
                        return dist <= 1
                    }
                }()

                if dismissOpacity > 0 || isExposeMode {
                    cardCell(for: agent, isExpose: isExposeMode, showContent: showContent, isKeyboardVisible: keyboardHeight > 0)
                        .frame(width: w, height: h)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard isExposeMode else { return }
                            store.focusedAgentId = agent.id
                            store.markReviewed(agentId: agent.id)
                            startTransition {
                                isExposeMode = false
                            }
                            hapticSnap.impactOccurred()
                        }
                        .position(x: x + dismissOffsetX, y: y)
                        .scaleEffect(dismissScale)
                        .opacity(dismissOpacity)
                        .zIndex(isFocused ? 1 : 0)
                }
            }
        }
        .contentShape(Rectangle())
        .clipped()
        .mask(
            VStack(spacing: 0) {
                if isExposeMode {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 80)
                } else {
                    Color.black.frame(height: 80)
                }
                Color.black
                if isExposeMode {
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 80)
                } else {
                    Color.black.frame(height: 80)
                }
            }
        )
        .overlay(
            Group {
                if !isExposeMode {
                    DirectionalPanOverlay(
                        dragOffset: $dragOffset,
                        gestureDirection: $gestureDirection,
                        onSwipeEnded: { finalOffset, predictedEnd in
                            let screenWidth = UIScreen.main.bounds.width
                            let threshold = screenWidth * 0.25
                            let idx = currentIndex

                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                if predictedEnd < -threshold && idx < visibleAgents.count - 1 {
                                    store.focusedAgentId = visibleAgents[idx + 1].id
                                    store.markReviewed(agentId: visibleAgents[idx + 1].id)
                                    hapticSnap.impactOccurred()
                                } else if predictedEnd > threshold && idx > 0 {
                                    store.focusedAgentId = visibleAgents[idx - 1].id
                                    store.markReviewed(agentId: visibleAgents[idx - 1].id)
                                    hapticSnap.impactOccurred()
                                }
                                dragOffset = 0
                            }
                        }
                    )
                }
            }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    guard isExposeMode else { return }
                    exposeScrollDragOffset = value.translation.height
                }
                .onEnded { value in
                    guard isExposeMode else { return }
                    let predictedEnd = value.predictedEndTranslation.height
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        exposeScrollOffset += predictedEnd
                        exposeScrollDragOffset = 0
                        if exposeScrollOffset > 0 { exposeScrollOffset = 0 }
                        let totalRows = ceil(Double(visibleAgents.count) / 3.0)
                        let screenHeight = UIScreen.main.bounds.height
                        let cellH: Double = 300
                        let spacing: Double = 32
                        let maxScroll = -(totalRows * (cellH + spacing) - Double(screenHeight) + 120)
                        if Double(exposeScrollOffset) < maxScroll {
                            exposeScrollOffset = CGFloat(maxScroll)
                        }
                    }
                }
        )
    }

    // MARK: - Transition Helper

    private func startTransition(modeChange: @escaping () -> Void) {
        // Phase 1: Fade out conversation (fast)
        withAnimation(.easeOut(duration: 0.12)) {
            conversationOpacity = 0
        }

        // Phase 2: After fade-out, REMOVE conversation views and animate positions
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            isTransitioning = true  // This removes ConversationViews from hierarchy

            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                modeChange()
                // Reset scroll offset when leaving exposé
                if !isExposeMode {
                    exposeScrollOffset = 0
                    exposeScrollDragOffset = 0
                }
            }

            // Phase 3: After cards settle, add conversation back and fade in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isTransitioning = false  // Re-add ConversationViews
                withAnimation(.easeIn(duration: 0.15)) {
                    conversationOpacity = 1.0
                }
            }
        }
    }

    private func cardOpacity(index: Int, focusedIndex: Int) -> Double {
        if isExposeMode { return 1.0 }
        let distance = abs(index - focusedIndex)
        if distance <= 1 { return 1.0 }
        return 0.0
    }

    @ViewBuilder
    private func cardCell(for agent: CoverflowAgent, isExpose: Bool, showContent: Bool, isKeyboardVisible: Bool = false) -> some View {
        CoverflowCardView(
            coverflowAgent: agent,
            conversationViewModel: store.conversationViewModel(for: agent),
            isExposeMode: isExpose,
            showConversation: showContent,
            conversationOpacity: conversationOpacity,
            isHorizontalSwiping: gestureDirection == .horizontal,
            isKeyboardVisible: isKeyboardVisible,
            onJumpToConversation: {
                // Navigate to this agent's conversation in the normal UI
                coordinator.onSelectAgent(agent.id, workspaceId: agent.workspaceId, agentName: agent.name)
                // Dismiss coverflow
                coordinator.showCoverflow = false
            }
        )
    }

    // MARK: - Page Indicator Dots

    @ViewBuilder
    private var pageIndicatorDots: some View {
        if visibleAgents.count > 1 {
            HStack(spacing: 6) {
                ForEach(0..<visibleAgents.count, id: \.self) { index in
                    Circle()
                        .fill(index == currentIndex
                            ? (colorScheme == .dark ? Color.white : Color.gray)
                            : (colorScheme == .dark ? Color.white.opacity(0.3) : Color.gray.opacity(0.3)))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.bottom, 30)
        }
    }

    // MARK: - Coverflow Action Buttons (shown in coverflow mode)

    @ViewBuilder
    private var coverflowActionButtons: some View {
        if let agent = focusedAgent {
            HStack(spacing: 12) {
                hideAgentButton(for: agent)
                exposeToggleButton
            }
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Exposé Action Buttons (shown in exposé mode)

    @ViewBuilder
    private var exposeActionButtons: some View {
        HStack(spacing: 12) {
            exposeToggleButton
        }
        .padding(.top, 4)
        .padding(.bottom, 24)
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private func hideAgentButton(for agent: CoverflowAgent) -> some View {
        Button {
            let nextAgent = visibleAgents.first { $0.id != agent.id }
            withAnimation(.easeInOut(duration: 0.3)) {
                dismissingAgentId = agent.id
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                store.focusedAgentId = nextAgent?.id
                dismissingAgentId = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    store.removeFromQueue(agentId: agent.id)
                }
                hapticSnap.impactOccurred()
            }
        } label: {
            Label("Hide Agent", systemImage: "xmark")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.foreground(for: colorScheme))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial.opacity(0.6))
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        }
    }

    @ViewBuilder
    private var exposeToggleButton: some View {
        Button {
            startTransition {
                isExposeMode.toggle()
            }
            hapticSnap.impactOccurred()
        } label: {
            Label(isExposeMode ? "Coverflow" : "Exposé",
                  systemImage: isExposeMode ? "rectangle.stack" : "square.grid.3x3")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.foreground(for: colorScheme))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial.opacity(0.6))
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        }
    }

    @ViewBuilder
    private var finishedBadge: some View {
        VStack {
            if store.finishedCount > 0 {
                Button {
                    // Navigate to the first unreviewed agent
                    if let firstUnreviewed = visibleAgents.first(where: { store.unreviewedAgentIds.contains($0.id) }) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            store.focusedAgentId = firstUnreviewed.id
                        }
                        store.markReviewed(agentId: firstUnreviewed.id)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("\(store.finishedCount) ready for review")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.foreground(for: colorScheme))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .scaleEffect(badgeBounce ? 1.15 : 1.0)
                    .padding(.top, 8)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .safeAreaPadding(.top)
    }

    // MARK: - Close Button

    @ViewBuilder
    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    coordinator.showCoverflow = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 36))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .frame(width: 44, height: 44)
                }
                .padding(.trailing, 16)
            }
            .padding(.top, 8)
            Spacer()
        }
        .safeAreaPadding(.top)
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 48))
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            Text("No agents in queue")
                .font(.title3.weight(.medium))
                .foregroundStyle(Theme.foreground(for: colorScheme))
            Text("Agents will appear here when they finish working.")
                .font(.subheadline)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }
}
