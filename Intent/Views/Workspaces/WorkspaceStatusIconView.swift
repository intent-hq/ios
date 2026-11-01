import SwiftUI

struct WorkspaceStatusIconView: View {
    let workspace: Workspace
    let colorScheme: ColorScheme
    var size: CGFloat = Constants.WorkspaceRow.statusIconSize
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var displayStatus: WorkspaceDisplayStatus {
        resolveDisplayStatus(for: workspace)
    }

    var body: some View {
        statusIcon
            .visionAttentionChipBrightness(workspaceNeedsInput(workspace))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilitySummary(for: workspace))
    }

    static func accessibilitySummary(for workspace: Workspace) -> String {
        var parts = [resolveDisplayStatus(for: workspace).label]
        if hasRunningAgents(workspace) { parts.append("Active agent") }
        if hasUnreadAttention(workspace) { parts.append("Unread attention") }
        if showsWaitingDot(workspace) { parts.append("Waiting") }
        return parts.joined(separator: ", ")
    }

    private var statusColor: Color {
        Self.statusColor(for: workspace, colorScheme: colorScheme, contrast: colorSchemeContrast)
    }

    static func statusColor(for workspace: Workspace, colorScheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        let displayStatus = resolveDisplayStatus(for: workspace)
        if contrast == .increased {
            switch displayStatus {
            case .idle, .notStarted, .unknown:
                return Theme.mutedForeground(for: colorScheme, contrast: contrast)
            default:
                break
            }
        }
        if displayStatus == .notStarted {
            return Constants.Colors.WorkspaceStatus.notStartedRing
        }
        return displayStatus.color
    }

    @ViewBuilder
    private var statusIcon: some View {
        ZStack {
            if displayStatus == .notStarted {
                Circle()
                    .strokeBorder(statusColor, lineWidth: Constants.WorkspaceRow.statusRingWidth)
            } else {
                Circle()
                    .fill(statusColor)
            }

            if differentiateWithoutColor {
                differentiatedIcon
                    .font(.system(size: size * Constants.WorkspaceRow.statusGlyphScale, weight: .bold))
                    .foregroundStyle(displayStatus == .notStarted ? statusColor : .white)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var differentiatedIcon: some View {
        switch displayStatus {
        case .failed: assetGlyph(.close)
        case .blocked: Image(systemName: "minus")
        case .needsAttention: Image(systemName: "exclamationmark")
        case .idle: assetGlyph(.pause)
        case .notStarted: assetGlyph(.stopFill)
        case .inProgress: assetGlyph(.playFill)
        case .complete, .prReady: assetGlyph(.check)
        case .prOpen: assetGlyph(.gitPr)
        case .prQueued: Image(systemName: "hourglass")
        case .prMerged: assetGlyph(.gitMerge)
        case .unknown: Image(systemName: "questionmark")
        }
    }

    private func assetGlyph(_ resource: ImageResource) -> some View {
        Image(resource)
            .resizable()
            .scaledToFit()
            .frame(
                width: size * Constants.WorkspaceRow.statusGlyphScale,
                height: size * Constants.WorkspaceRow.statusGlyphScale
            )
            .accessibilityHidden(true)
    }
}
