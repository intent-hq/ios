import SwiftUI

struct WorkspaceStatusSwipeBadge: View {
    let workspace: Workspace
    let progress: CGFloat
    let availableWidth: CGFloat
    var dotSize: CGFloat = Constants.WorkspaceRow.statusIconSize
    let onSizeChanged: (CGSize) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let status = resolveDisplayStatus(for: workspace)
        SwipeMorphBadge(
            fill: WorkspaceStatusIconView.statusColor(for: workspace, colorScheme: colorScheme, contrast: contrast),
            image: status.swipeImage,
            title: status == .blocked ? "Blocker" : status.label,
            progress: progress,
            availableWidth: availableWidth,
            dotSize: dotSize,
            onSizeChanged: onSizeChanged
        ) {
            WorkspaceStatusIconView(workspace: workspace, colorScheme: colorScheme, size: dotSize)
        }
    }
}

/// A row's leading icon that grows into a labelled pill as the row is
/// swiped right, naming the action the completed swipe performs.
struct SwipeMorphBadge<Dot: View>: View {
    let fill: Color
    let image: ImageResource
    let title: String
    let progress: CGFloat
    let availableWidth: CGFloat
    var dotSize: CGFloat = Constants.WorkspaceRow.statusIconSize
    let onSizeChanged: (CGSize) -> Void
    @ViewBuilder let dot: () -> Dot
    @State private var labelSize = CGSize(width: SwipeMorphBadgeStyle.initialWidth, height: SwipeMorphBadgeStyle.height)

    private var expansion: CGFloat { min(1, max(0, progress)) }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: min(size.height / 2, SwipeMorphBadgeStyle.cornerRadius), style: .continuous)
    }
    private var size: CGSize {
        CGSize(
            width: dotSize + (min(labelSize.width, max(dotSize, availableWidth)) - dotSize) * expansion,
            height: dotSize + (labelSize.height - dotSize) * expansion
        )
    }

    var body: some View {
        ZStack(alignment: .leading) {
            shape
                .fill(fill)
                .frame(width: size.width, height: size.height)
                .opacity(expansion > 0 ? 1 : 0)
            label
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { measured in
                    labelSize = measured
                    onSizeChanged(measured)
                }
                .opacity(Double(max(0, (expansion - SwipeMorphBadgeStyle.labelFadeStart) / (1 - SwipeMorphBadgeStyle.labelFadeStart))))
                .mask(alignment: .leading) { shape.frame(width: size.width, height: size.height) }
            dot()
                .opacity(Double(max(0, 1 - expansion / SwipeMorphBadgeStyle.dotFadeEnd)))
        }
        .frame(width: dotSize, height: dotSize, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var label: some View {
        HStack(spacing: SwipeMorphBadgeStyle.spacing) {
            Image(image)
                .resizable()
                .scaledToFit()
                .frame(width: SwipeMorphBadgeStyle.iconSize, height: SwipeMorphBadgeStyle.iconSize)
                .accessibilityHidden(true)
            Text(title)
                .interFont(Constants.Typography.bodySEmphasized)
                .lineLimit(1)
                .frame(maxWidth: max(1, availableWidth - SwipeMorphBadgeStyle.labelInsets))
        }
        .foregroundStyle(Constants.Pairing.onAccent)
        .padding(.leading, SwipeMorphBadgeStyle.leadingInset)
        .padding(.trailing, SwipeMorphBadgeStyle.trailingInset)
        .padding(.vertical, SwipeMorphBadgeStyle.verticalInset)
        .frame(minHeight: SwipeMorphBadgeStyle.height)
    }
}

private enum SwipeMorphBadgeStyle {
    static let initialWidth: CGFloat = 136
    static let height: CGFloat = 48
    static let cornerRadius: CGFloat = 20
    static let iconSize: CGFloat = 24
    static let spacing: CGFloat = 16
    static let leadingInset: CGFloat = 16
    static let trailingInset: CGFloat = 24
    static let verticalInset: CGFloat = 12
    static let labelInsets = iconSize + spacing + leadingInset + trailingInset
    static let labelFadeStart: CGFloat = 0.25
    static let dotFadeEnd: CGFloat = 0.15
}

private extension WorkspaceDisplayStatus {
    var swipeImage: ImageResource {
        switch self {
        case .blocked, .failed, .needsAttention: .attentionCircle
        case .inProgress: .play
        case .complete, .prReady: .checkCircle
        case .idle: .pause
        case .notStarted: .stop
        case .prOpen: .gitBranch
        case .prQueued: .historyCircle3
        case .prMerged: .gitMerge
        case .unknown: .questionCircle
        }
    }
}
