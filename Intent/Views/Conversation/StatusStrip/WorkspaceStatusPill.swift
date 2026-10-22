import SwiftUI

/// Capsule shared by the status pills above the workspace composer. Pills hug
/// their content so several can share one row.
struct WorkspaceStatusPill<Trailing: View>: View {
    let icon: ImageResource
    let text: Text
    var truncates = false
    @ViewBuilder var trailing: Trailing
    @Environment(\.colorScheme) private var colorScheme

    private typealias Design = Constants.Conversation.Design

    var body: some View {
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

extension WorkspaceStatusPill where Trailing == EmptyView {
    init(icon: ImageResource, text: Text, truncates: Bool = false) {
        self.init(icon: icon, text: text, truncates: truncates) { EmptyView() }
    }
}

// Generic types cannot hold static stored properties, so the timing lives here.
private enum MarqueeMotion {
    static let pointsPerSecond: Double = 60
    static let maximumDuration: Double = 3
    static let startDelay: Duration = .seconds(1)
    static let endPauseSeconds: Double = 1.5
    // Lets the overlay mount at rest before its offset changes.
    static let overlayDelaySeconds: Double = 0.05
}

/// One line that scrolls once to show an overflowing end, then returns to its truncated start.
/// Reduce Motion keeps it truncated; a single pass keeps UI tests idle afterwards.
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
                        // Declared on the moving text so a parent's animation reset cannot remove it.
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
        // The deferred reset returns to the truncated start without scrolling back.
        try? await Task.sleep(for: .seconds(duration + MarqueeMotion.endPauseSeconds))
    }
}

/// One row above the workspace composer: PR monitors first, then script watches.
struct WorkspaceStatusPillsRow: View {
    let viewModel: ConversationViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection

    private typealias Design = Constants.Conversation.Design

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Design.Status.composerSpacing))
            : AnyLayout(WorkspaceStatusPillsLayout(spacing: Design.Status.composerSpacing, layoutDirection: layoutDirection))
        layout {
            if viewModel.showsPrMonitorStatus {
                MonitoredPrsRow(viewModel: viewModel, monitoredPrStore: viewModel.monitoredPrStore, usesWorkspaceDesign: true)
            }
            if viewModel.showsScriptMonitorStatus {
                ScriptWatchPills(viewModel: viewModel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            #if DEBUG
            if DemoMode.isEnabled, ProcessInfo.processInfo.arguments.contains("--demo-script-monitor-hit-probe") {
                DemoIPadPaneGeometry(identifier: "workspace-status-pills")
            }
            #endif
        }
    }
}

/// Equal width limits keep short pills compact; rows stack when minimum widths cannot fit.
struct WorkspaceStatusPillsLayout: Layout {
    var spacing: CGFloat
    var layoutDirection: LayoutDirection

    private nonisolated struct Measurement {
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
        showsPrMonitorStatus || showsScriptMonitorStatus
    }
}
