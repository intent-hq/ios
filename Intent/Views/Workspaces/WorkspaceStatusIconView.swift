import SwiftUI

struct WorkspaceStatusIconView: View {
    private static let increasedStrokeScale: CGFloat = 1.5
    private static let differentiatedIdleGlyphScale: CGFloat = 0.35

    let workspace: Workspace
    let colorScheme: ColorScheme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var displayStatus: WorkspaceDisplayStatus {
        resolveDisplayStatus(for: workspace)
    }

    private var hasActiveAgents: Bool {
        hasRunningAgents(workspace)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            statusIcon

            if hasActiveAgents {
                statusDot(color: .green, differentiatedSymbol: "bolt.fill")
                    .offset(x: statusCueOffset, y: -statusCueOffset)
            }

            // Blue dot: server-owned unread attention flag, overlaying the
            // real status; cleared via workspace.markSeen on open.
            if hasUnreadAttention(workspace) {
                statusDot(
                    color: kWorkspaceUnreadColor,
                    differentiatedSymbol: "exclamationmark.triangle.fill"
                )
                    .offset(
                        x: statusCueOffset,
                        y: hasActiveAgents ? unreadStatusCueStackOffset : -statusCueOffset
                    )
            }

            // Grey static dot: orthogonal waiting flag (protocol 6.17).
            // Lowest precedence — running and unread dots win.
            if showsWaitingDot(workspace) {
                statusDot(color: .gray, differentiatedSymbol: "clock.fill")
                    .offset(x: statusCueOffset, y: -statusCueOffset)
            }
        }
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

    private var statusStrokeWidth: CGFloat {
        Constants.WorkspaceRow.statusStrokeWidth
            * (colorSchemeContrast == .increased ? Self.increasedStrokeScale : 1)
    }

    private var statusCueSize: CGFloat {
        differentiateWithoutColor
            ? Constants.WorkspaceRow.differentiatedStatusCueSize
            : Constants.WorkspaceRow.statusDotSize
    }

    private var statusCueOffset: CGFloat {
        differentiateWithoutColor
            ? Constants.WorkspaceRow.differentiatedStatusCueOffset
            : Constants.WorkspaceRow.statusDotOffset
    }

    private var unreadStatusCueStackOffset: CGFloat {
        differentiateWithoutColor
            ? Constants.WorkspaceRow.differentiatedUnreadStackOffset
            : Constants.WorkspaceRow.unreadDotStackOffset
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
        return displayStatus.color
    }

    @ViewBuilder
    private var statusIcon: some View {
        let size = Constants.WorkspaceRow.statusIconSize
        let color = statusColor

        switch displayStatus {
        case .failed:
            // Filled red circle with an xmark
            ZStack {
                Circle()
                    .fill(color)
                Image(systemName: "xmark")
                    .font(.system(size: size * Constants.WorkspaceRow.statusGlyphScale, weight: .bold))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }
            .frame(width: size, height: size)

        case .blocked:
            // Filled red circle with a minus (blocker attention request)
            ZStack {
                Circle()
                    .fill(color)
                Image(systemName: "minus")
                    .font(.system(size: size * Constants.WorkspaceRow.statusGlyphScale, weight: .bold))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }
            .frame(width: size, height: size)

        case .needsAttention:
            // Filled amber circle with exclamation mark
            ZStack {
                Circle()
                    .fill(color)
                Image(systemName: "exclamationmark")
                    .font(.system(size: size * Constants.WorkspaceRow.statusGlyphScale, weight: .bold))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }
            .frame(width: size, height: size)

        case .notStarted:
            // Empty outline circle
            Circle()
                .strokeBorder(
                    color.opacity(colorSchemeContrast == .increased
                        ? 1
                        : Constants.WorkspaceRow.inactiveStatusOpacity),
                    lineWidth: statusStrokeWidth
                )
                .frame(width: size, height: size)

        case .idle:
            // Empty outline circle in the idle muted color
            ZStack {
                Circle()
                    .strokeBorder(color, lineWidth: statusStrokeWidth)
                if differentiateWithoutColor {
                    Image(systemName: "pause.fill")
                        .font(.system(size: size * Self.differentiatedIdleGlyphScale, weight: .bold))
                        .foregroundStyle(color)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: size, height: size)

        case .inProgress:
            // Half-filled circle (right half)
            ZStack {
                Circle()
                    .stroke(color, lineWidth: statusStrokeWidth)
                Circle()
                    .fill(color)
                    .clipShape(HalfCircle())
            }
            .frame(width: size, height: size)

        case .complete:
            // Filled circle with checkmark
            ZStack {
                Circle()
                    .fill(color)
                Image(systemName: "checkmark")
                    .font(.system(size: size * Constants.WorkspaceRow.statusGlyphScale, weight: .bold))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }
            .frame(width: size, height: size)

        case .prOpen:
            ZStack {
                Circle()
                    .fill(color)
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: size * Constants.WorkspaceRow.statusGlyphScale, weight: .bold))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }
            .frame(width: size, height: size)

        case .prReady:
            ZStack {
                Circle()
                    .fill(color)
                Image(systemName: differentiateWithoutColor ? "checkmark" : "arrow.triangle.pull")
                    .font(.system(size: size * Constants.WorkspaceRow.statusGlyphScale, weight: .bold))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }
            .frame(width: size, height: size)

        case .prQueued:
            // Filled circle with hourglass (PR sitting in the merge queue)
            ZStack {
                Circle()
                    .fill(color)
                Image(systemName: "hourglass")
                    .font(.system(size: size * Constants.WorkspaceRow.statusGlyphScale, weight: .bold))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }
            .frame(width: size, height: size)

        case .prMerged:
            // Filled circle with merge icon
            ZStack {
                Circle()
                    .fill(color)
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: size * Constants.WorkspaceRow.statusGlyphScale, weight: .bold))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }
            .frame(width: size, height: size)

        case .unknown:
            // Neutral question mark for a wire value this build doesn't know
            ZStack {
                Circle()
                    .strokeBorder(color, lineWidth: statusStrokeWidth)
                Image(systemName: "questionmark")
                    .font(.system(size: size * Constants.WorkspaceRow.statusGlyphScale, weight: .bold))
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
            }
            .frame(width: size, height: size)
        }
    }

    @ViewBuilder
    private func statusDot(color: Color, differentiatedSymbol: String) -> some View {
        if differentiateWithoutColor {
            Image(systemName: differentiatedSymbol)
                .font(.system(size: statusCueSize, weight: .bold))
                .foregroundStyle(color)
                .frame(width: statusCueSize, height: statusCueSize)
                .accessibilityHidden(true)
        } else {
            Circle()
                .fill(color)
                .frame(
                    width: Constants.WorkspaceRow.statusDotSize,
                    height: Constants.WorkspaceRow.statusDotSize
                )
        }
    }
}

nonisolated struct HalfCircle: Shape {
    private static let startAngle = Angle.radians(-.pi / 2)
    private static let endAngle = Angle.radians(.pi / 2)

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: rect.width / 2,
            startAngle: Self.startAngle,
            endAngle: Self.endAngle,
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
