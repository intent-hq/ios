import SwiftUI

struct WorkspaceStatusIconView: View {
    let workspace: Workspace
    let colorScheme: ColorScheme
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
        if colorSchemeContrast == .increased {
            switch displayStatus {
            case .idle, .notStarted, .unknown:
                return Theme.mutedForeground(for: colorScheme, contrast: colorSchemeContrast)
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
        let size = Constants.WorkspaceRow.statusIconSize

        ZStack {
            if displayStatus == .notStarted {
                Circle()
                    .strokeBorder(statusColor, lineWidth: Constants.WorkspaceRow.statusRingWidth)
            } else {
                Circle()
                    .fill(statusColor)
            }

            if differentiateWithoutColor {
                Image(systemName: differentiatedSymbol)
                    .font(.system(size: size * Constants.WorkspaceRow.statusGlyphScale, weight: .bold))
                    .foregroundStyle(displayStatus == .notStarted ? statusColor : .white)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size, height: size)
    }

    private var differentiatedSymbol: String {
        switch displayStatus {
        case .failed: "xmark"
        case .blocked: "minus"
        case .needsAttention: "exclamationmark"
        case .idle: "pause.fill"
        case .notStarted: "stop.fill"
        case .inProgress: "play.fill"
        case .complete, .prReady: "checkmark"
        case .prOpen: "arrow.triangle.pull"
        case .prQueued: "hourglass"
        case .prMerged: "arrow.triangle.merge"
        case .unknown: "questionmark"
        }
    }
}
