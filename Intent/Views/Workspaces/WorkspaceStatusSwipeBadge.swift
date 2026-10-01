import SwiftUI

struct WorkspaceStatusSwipeBadge: View {
    let workspace: Workspace
    let progress: CGFloat
    let availableWidth: CGFloat
    let onSizeChanged: (CGSize) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var labelSize = CGSize(width: Style.initialWidth, height: Style.height)

    private var status: WorkspaceDisplayStatus { resolveDisplayStatus(for: workspace) }
    private var expansion: CGFloat { min(1, max(0, progress)) }
    private var dotSize: CGFloat { Constants.WorkspaceRow.statusIconSize }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: min(size.height / 2, Style.cornerRadius), style: .continuous)
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
                .fill(WorkspaceStatusIconView.statusColor(for: workspace, colorScheme: colorScheme, contrast: contrast))
                .frame(width: size.width, height: size.height)
                .opacity(expansion > 0 ? 1 : 0)
            label
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { measured in
                    labelSize = measured
                    onSizeChanged(measured)
                }
                .opacity(Double(max(0, (expansion - Style.labelFadeStart) / (1 - Style.labelFadeStart))))
                .mask(alignment: .leading) { shape.frame(width: size.width, height: size.height) }
            WorkspaceStatusIconView(workspace: workspace, colorScheme: colorScheme)
                .opacity(Double(max(0, 1 - expansion / Style.dotFadeEnd)))
        }
        .frame(width: dotSize, height: dotSize, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var label: some View {
        HStack(spacing: Style.spacing) {
            Image(status.swipeImage)
                .resizable()
                .scaledToFit()
                .frame(width: Style.iconSize, height: Style.iconSize)
                .accessibilityHidden(true)
            Text(status == .blocked ? "Blocker" : status.label)
                .interFont(Constants.Typography.bodySEmphasized)
                .lineLimit(1)
                .frame(maxWidth: max(1, availableWidth - Style.labelInsets))
        }
        .foregroundStyle(Constants.Pairing.onAccent)
        .padding(.leading, Style.leadingInset)
        .padding(.trailing, Style.trailingInset)
        .padding(.vertical, Style.verticalInset)
        .frame(minHeight: Style.height)
    }

    private enum Style {
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
