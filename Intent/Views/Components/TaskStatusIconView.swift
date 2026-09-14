import SwiftUI

/// Compact circular task status indicator, visually matching the desktop
/// frontend's `TaskStatusIcon.svelte`:
/// - notStarted: empty gray outline circle; unknown adds a question mark
/// - waiting: gray outline circle with a clock glyph (deliberate addition;
///   the fe currently renders waiting identically to not_started)
/// - discussionNeeded: amber filled circle with a question mark
/// - blocked: red filled circle with an exclamation mark
/// - inProgress: blue outline, right half filled
/// - reviewRequired: blue filled circle with an eye
/// - complete: green filled circle with a white checkmark
/// - cancelled: gray outline circle with a diagonal line
///
/// All geometry is defined in the fe's 24×24 viewBox space and scaled to `size`.
struct TaskStatusIconView: View {
    let status: TaskDisplayStatus
    var size: CGFloat = 16
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    /// Scale factor from the 24×24 reference space to the rendered size.
    private var scale: CGFloat { size / 24 }

    private var statusStrokeWidth: CGFloat {
        (colorSchemeContrast == .increased ? 3.5 : 2.5) * scale
    }

    private var neutralColor: Color {
        colorSchemeContrast == .increased ? .primary.opacity(0.75) : Palette.gray
    }

    /// Shared task-status palette; `amber` doubles as the warning color for
    /// conflict relation chips (fe `text-warning`).
    enum Palette {
        // #99999966
        static let gray = Constants.Colors.TaskStatus.neutral
        // #f59e0b
        static let amber = Constants.Colors.TaskStatus.warning
        // #ef4444
        static let red = Constants.Colors.TaskStatus.blocked
        // #00BCFF
        static let skyBlue = Constants.Colors.TaskStatus.inProgress
        // #3b82f6
        static let blue = Constants.Colors.TaskStatus.reviewRequired
        // #22c55e
        static let greenStroke = Constants.Colors.TaskStatus.completeStroke
        // #00BD7D
        static let greenFill = Constants.Colors.TaskStatus.completeFill
    }

    /// Outline stroke color per status.
    private var strokeColor: Color {
        switch status {
        case .notStarted, .waiting, .cancelled, .unknown: return neutralColor
        case .discussionNeeded: return Palette.amber
        case .blocked: return Palette.red
        case .inProgress: return Palette.skyBlue
        case .reviewRequired: return Palette.blue
        case .complete: return Palette.greenStroke
        }
    }

    /// Inner fill circle: color and radius in reference units (nil = no fill).
    /// Cancelled has no fill in the fe (innerCircleRPercentage 0) — it renders
    /// as a gray outline with a diagonal line.
    private var fill: (color: Color, radius: CGFloat)? {
        switch status {
        case .notStarted, .waiting, .cancelled, .unknown: return nil
        case .discussionNeeded: return (Palette.amber, 12)
        case .blocked: return (Palette.red, 12)
        case .inProgress: return (Palette.skyBlue, 6.6)
        case .reviewRequired: return (Palette.blue, 12)
        case .complete: return (Palette.greenFill, 12)
        }
    }

    var body: some View {
        ZStack {
            if let fill {
                fillCircle(color: fill.color, radius: fill.radius)
            }
            Circle()
                .stroke(strokeColor, lineWidth: statusStrokeWidth)
                .frame(width: 21.6 * scale, height: 21.6 * scale)
            if status == .inProgress {
                // fe draws an extra inner ring (r=10, width 2) that thickens
                // the in-progress outline inward.
                Circle()
                    .stroke(strokeColor, lineWidth: 2 * scale)
                    .frame(width: 20 * scale, height: 20 * scale)
            }
            glyph
        }
        .frame(width: size, height: size)
        .accessibilityLabel(status.label)
    }

    @ViewBuilder
    private func fillCircle(color: Color, radius: CGFloat) -> some View {
        let circle = Circle()
            .fill(color)
            .frame(width: radius * 2 * scale, height: radius * 2 * scale)
        if status == .inProgress {
            // Half fill: only the part right of x = 11.52 (48% of 24) is visible.
            // The fill circle spans x ∈ [12 − radius, 12 + radius]. The mask is
            // pinned to LTR so the visible half never flips under RTL (the fe
            // clip is an absolute x=48% rect).
            circle.mask(
                Rectangle()
                    .padding(.leading, (11.52 - (12 - radius)) * scale)
                    .environment(\.layoutDirection, .leftToRight)
            )
        } else {
            circle
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch status {
        case .notStarted, .inProgress:
            EmptyView()
        case .unknown:
            Image(systemName: "questionmark")
                .font(.system(size: 11 * scale, weight: .bold))
                .foregroundStyle(neutralColor)
                .accessibilityHidden(true)
        case .waiting:
            Image(systemName: "clock")
                .font(.system(size: 11 * scale, weight: .medium))
                .foregroundStyle(neutralColor)
                .accessibilityHidden(true)
        case .discussionNeeded:
            Image(systemName: "questionmark")
                .font(.system(size: 12 * scale, weight: .bold))
                .foregroundStyle(.white)
                .accessibilityHidden(true)
        case .blocked:
            Path { p in
                p.move(to: point(12, 5.5))
                p.addLine(to: point(12, 13.5))
            }
            .stroke(.white, style: StrokeStyle(lineWidth: 3 * scale, lineCap: .round))
            Circle()
                .fill(.white)
                .frame(width: 3.2 * scale, height: 3.2 * scale)
                .offset(y: 5.5 * scale)
        case .reviewRequired:
            Image(systemName: "eye.fill")
                .font(.system(size: 10 * scale, weight: .regular))
                .foregroundStyle(.white)
                .accessibilityHidden(true)
        case .complete:
            Path { p in
                p.move(to: point(7, 12.5))
                p.addLine(to: point(10.5, 16))
                p.addLine(to: point(17, 9))
            }
            .stroke(
                .white,
                style: StrokeStyle(lineWidth: 3.5 * scale, lineCap: .round, lineJoin: .round)
            )
        case .cancelled:
            Path { p in
                p.move(to: point(5, 19))
                p.addLine(to: point(19, 5))
            }
            .stroke(neutralColor, style: StrokeStyle(lineWidth: statusStrokeWidth, lineCap: .round))
        }
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * scale, y: y * scale)
    }
}

#Preview("All statuses") {
    let statuses: [TaskDisplayStatus] = [
        .notStarted,
        .waiting,
        .discussionNeeded,
        .blocked,
        .inProgress,
        .reviewRequired,
        .complete,
        .cancelled,
        .unknown
    ]
    VStack(spacing: 12) {
        ForEach([16, 24, 48] as [CGFloat], id: \.self) { size in
            HStack(spacing: 8) {
                ForEach(Array(statuses.enumerated()), id: \.offset) { _, status in
                    TaskStatusIconView(status: status, size: size)
                }
            }
        }
    }
    .padding()
}
