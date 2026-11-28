import SwiftUI

struct WorkspaceStatusPill<Trailing: View>: View {
    let icon: ImageResource
    let text: Text
    var truncates = false
    @ViewBuilder var trailing: Trailing
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .footnote) private var maximumWidth = Constants.Conversation.Design.Status.pillMaximumWidth

    private typealias Design = Constants.Conversation.Design

    var body: some View {
        WidthCappedLayout(maximumWidth: maximumWidth) { pill }
    }

    private var pill: some View {
        HStack(spacing: Design.Status.iconSpacing) {
            Image(icon)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: Design.smallIconSize, height: Design.smallIconSize)
                .accessibilityHidden(true)
            if truncates {
                MarqueeText { text.interFont(Design.Typography.status) }
            } else {
                text
                    .interFont(Design.Typography.status)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            trailing
        }
        .foregroundStyle(Design.Palette.foreground(for: colorScheme))
        .padding(.leading, Design.Status.leadingPadding)
        .padding(.trailing, Design.Status.trailingPadding)
        .frame(minHeight: Design.Status.minimumHeight)
        .background(Design.Palette.surface(for: colorScheme), in: Capsule())
        .frame(minHeight: Design.minimumTapTarget)
        .contentShape(Rectangle())
    }
}

struct WidthCappedLayout: Layout {
    let maximumWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(cappedProposal(proposal)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: cappedProposal(proposal))
    }

    private func cappedProposal(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: min(proposal.width ?? maximumWidth, maximumWidth), height: proposal.height)
    }
}

extension WorkspaceStatusPill where Trailing == EmptyView {
    init(icon: ImageResource, text: Text, truncates: Bool = false) {
        self.init(icon: icon, text: text, truncates: truncates) { EmptyView() }
    }
}

private enum MarqueeMotion {
    static let pointsPerSecond: Double = 60
    static let maximumDuration: Double = 3
    static let startDelay: Duration = .seconds(1)
    static let endPauseSeconds: Double = 1.5
    static let overlayDelaySeconds: Double = 0.05
}

struct MarqueeText<Content: View>: View {
    @ViewBuilder let text: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fullWidth: CGFloat = 0
    @State private var visibleWidth: CGFloat = 0
    @State private var isRevealing = false
    @State private var isScrolled = false
    @State private var scrollDuration: Double = 0

    private var overflow: CGFloat { max(0, fullWidth - visibleWidth) }

    var body: some View {
        text
            .lineLimit(1)
            .truncationMode(.tail)
            .opacity(isRevealing ? 0 : 1)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { visibleWidth = $0 }
            .background(alignment: .leading) {
                text
                    .lineLimit(1)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fullWidth = $0 }
            }
            .overlay(alignment: .leading) {
                if isRevealing {
                    text
                        .lineLimit(1)
                        .fixedSize()
                        .offset(x: isScrolled ? -overflow : 0)
                        .animation(.linear(duration: scrollDuration), value: isScrolled)
                        .accessibilityHidden(true)
                }
            }
            .clipped()
            .task(id: reduceMotion ? 0 : overflow) { await reveal() }
    }

    private func reveal() async {
        defer {
            isRevealing = false
            isScrolled = false
        }
        guard overflow > 0, !reduceMotion else { return }
        let duration = min(Double(overflow) / MarqueeMotion.pointsPerSecond, MarqueeMotion.maximumDuration)
        scrollDuration = duration
        try? await Task.sleep(for: MarqueeMotion.startDelay)
        guard !Task.isCancelled else { return }
        isRevealing = true
        try? await Task.sleep(for: .seconds(MarqueeMotion.overlayDelaySeconds))
        isScrolled = true
        try? await Task.sleep(for: .seconds(duration + MarqueeMotion.endPauseSeconds))
    }
}

struct WorkspaceStatusPillsRow: View {
    let viewModel: ConversationViewModel
    var horizontalInset: CGFloat = 0
    @State private var hasMoreTrailing = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private typealias Design = Constants.Conversation.Design

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Design.Status.composerSpacing) { pills }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, horizontalInset)
            } else {
                scrollingPills
            }
        }
        .background {
            #if DEBUG
            if DemoMode.isEnabled, LaunchOptions.current.contains("--demo-script-monitor-hit-probe") {
                DemoIPadPaneGeometry(identifier: "workspace-status-pills")
            }
            #endif
        }
    }

    private var scrollingPills: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Design.Status.composerSpacing) { pills }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, horizontalInset, for: .scrollContent)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.width + geometry.contentInsets.trailing
                - geometry.contentOffset.x - geometry.containerSize.width > 1
        } action: { _, hasMore in
            hasMoreTrailing = hasMore
        }
        .mask {
            HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, hasMoreTrailing ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Design.Status.trailingFadeWidth)
            }
        }
        .animation(.easeInOut(duration: Design.Status.trailingFadeDuration), value: hasMoreTrailing)
    }

    @ViewBuilder private var pills: some View {
        if let goal = viewModel.conversationGoal {
            ConversationGoalPill(
                goal: goal,
                onSave: { await viewModel.saveGoal($0) },
                onRemove: { await viewModel.removeGoal() }
            )
        }
        if viewModel.showsPrMonitorStatus {
            MonitoredPrsRow(viewModel: viewModel, monitoredPrStore: viewModel.monitoredPrStore, usesWorkspaceDesign: true)
        }
        if viewModel.showsScriptMonitorStatus {
            ScriptWatchPills(viewModel: viewModel)
        }
    }
}

struct WorkspaceStatusPillsLayout: Layout {
    var spacing: CGFloat
    var layoutDirection: LayoutDirection

    nonisolated private struct Measurement {
        let sizes: [CGSize]
        let proposal: ProposedViewSize
        let stacks: Bool
    }

    private func measurement(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> Measurement {
        let availableWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let gaps = spacing * CGFloat(max(0, subviews.count - 1))
        let width = availableWidth.map { max(0, $0 - gaps) / CGFloat(max(1, subviews.count)) }
        let childProposal = ProposedViewSize(width: width, height: nil)
        let sizes = subviews.map { $0.sizeThatFits(childProposal) }
        if let width, sizes.contains(where: { $0.width > width.nextUp }) {
            let stackedProposal = ProposedViewSize(width: availableWidth, height: nil)
            return Measurement(sizes: subviews.map { $0.sizeThatFits(stackedProposal) }, proposal: stackedProposal, stacks: true)
        }
        return Measurement(sizes: sizes, proposal: childProposal, stacks: false)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let measured = measurement(proposal: proposal, subviews: subviews)
        let gaps = spacing * CGFloat(subviews.count - 1)
        return CGSize(
            width: measured.stacks ? measured.sizes.map(\.width).max() ?? 0 : measured.sizes.reduce(0) { $0 + $1.width } + gaps,
            height: measured.stacks ? measured.sizes.reduce(0) { $0 + $1.height } + gaps : measured.sizes.map(\.height).max() ?? 0
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let measured = measurement(proposal: proposal, subviews: subviews)
        let isRightToLeft = layoutDirection == .rightToLeft
        var position = isRightToLeft ? bounds.maxX : bounds.minX
        var top = bounds.minY
        for (subview, size) in zip(subviews, measured.sizes) {
            subview.place(
                at: CGPoint(x: isRightToLeft ? position - size.width : position, y: measured.stacks ? top : bounds.midY - size.height / 2),
                proposal: measured.proposal
            )
            if measured.stacks {
                top += size.height + spacing
            } else {
                position += (size.width + spacing) * (isRightToLeft ? -1 : 1)
            }
        }
    }
}

extension ConversationViewModel {
    var showsPrMonitorStatus: Bool {
        !activeAgentMonitors.isEmpty || monitoredPrStore.error != nil
    }

    var showsWorkspaceStatusPills: Bool {
        conversationGoal != nil || showsPrMonitorStatus || showsScriptMonitorStatus
    }
}
