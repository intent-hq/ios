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
    var size: CGFloat = Metrics.defaultSize
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private typealias Metrics = Constants.TaskStatusIcon

    /// Scale factor from the 24×24 reference space to the rendered size.
    private var scale: CGFloat { size / Metrics.referenceSize }

    private var statusStrokeWidth: CGFloat {
        let referenceWidth = colorSchemeContrast == .increased
            ? Metrics.increasedContrastStrokeWidth
            : Metrics.standardStrokeWidth
        return referenceWidth * scale
    }

    private var neutralColor: Color {
        colorSchemeContrast == .increased
            ? .primary.opacity(Metrics.increasedContrastNeutralOpacity)
            : Palette.gray
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
        case .discussionNeeded: return (Palette.amber, Metrics.fullFillRadius)
        case .blocked: return (Palette.red, Metrics.fullFillRadius)
        case .inProgress: return (Palette.skyBlue, Metrics.inProgressFillRadius)
        case .reviewRequired: return (Palette.blue, Metrics.fullFillRadius)
        case .complete: return (Palette.greenFill, Metrics.fullFillRadius)
        }
    }

    var body: some View {
        ZStack {
            if let fill {
                fillCircle(color: fill.color, radius: fill.radius)
            }
            Circle()
                .stroke(strokeColor, lineWidth: statusStrokeWidth)
                .frame(
                    width: Metrics.outerCircleDiameter * scale,
                    height: Metrics.outerCircleDiameter * scale
                )
            if status == .inProgress {
                // fe draws an extra inner ring (r=10, width 2) that thickens
                // the in-progress outline inward.
                Circle()
                    .stroke(strokeColor, lineWidth: Metrics.inProgressInnerStrokeWidth * scale)
                    .frame(
                        width: Metrics.inProgressInnerDiameter * scale,
                        height: Metrics.inProgressInnerDiameter * scale
                    )
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
            .frame(
                width: radius * Metrics.diameterMultiplier * scale,
                height: radius * Metrics.diameterMultiplier * scale
            )
        if status == .inProgress {
            // Half fill: only the part right of x = 11.52 (48% of 24) is visible.
            // The fill circle spans x ∈ [12 − radius, 12 + radius]. The mask is
            // pinned to LTR so the visible half never flips under RTL (the fe
            // clip is an absolute x=48% rect).
            circle.mask(
                Rectangle()
                    .padding(
                        .leading,
                        (Metrics.inProgressClipLeadingX - (Metrics.fullFillRadius - radius)) * scale
                    )
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
                .font(.system(size: Metrics.secondaryGlyphSize * scale, weight: .bold))
                .foregroundStyle(neutralColor)
                .accessibilityHidden(true)
        case .waiting:
            Image(systemName: "clock")
                .font(.system(size: Metrics.secondaryGlyphSize * scale, weight: .medium))
                .foregroundStyle(neutralColor)
                .accessibilityHidden(true)
        case .discussionNeeded:
            Image(systemName: "questionmark")
                .font(.system(size: Metrics.questionGlyphSize * scale, weight: .bold))
                .foregroundStyle(.white)
                .accessibilityHidden(true)
        case .blocked:
            // Path coordinates are intrinsic vector artwork data.
            // swiftlint:disable no_magic_numbers
            Path { p in
                p.move(to: point(12, 5.5))
                p.addLine(to: point(12, 13.5))
            }
            // swiftlint:enable no_magic_numbers
            .stroke(
                .white,
                style: StrokeStyle(lineWidth: Metrics.blockedGlyphStrokeWidth * scale, lineCap: .round)
            )
            Circle()
                .fill(.white)
                .frame(
                    width: Metrics.blockedDotDiameter * scale,
                    height: Metrics.blockedDotDiameter * scale
                )
                .offset(y: Metrics.blockedDotOffset * scale)
        case .reviewRequired:
            Image(systemName: "eye.fill")
                .font(.system(size: Metrics.eyeGlyphSize * scale, weight: .regular))
                .foregroundStyle(.white)
                .accessibilityHidden(true)
        case .complete:
            // Path coordinates are intrinsic vector artwork data.
            // swiftlint:disable no_magic_numbers
            Path { p in
                p.move(to: point(7, 12.5))
                p.addLine(to: point(10.5, 16))
                p.addLine(to: point(17, 9))
            }
            // swiftlint:enable no_magic_numbers
            .stroke(
                .white,
                style: StrokeStyle(
                    lineWidth: Metrics.completeGlyphStrokeWidth * scale,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        case .cancelled:
            // Path coordinates are intrinsic vector artwork data.
            // swiftlint:disable no_magic_numbers
            Path { p in
                p.move(to: point(5, 19))
                p.addLine(to: point(19, 5))
            }
            // swiftlint:enable no_magic_numbers
            .stroke(neutralColor, style: StrokeStyle(lineWidth: statusStrokeWidth, lineCap: .round))
        }
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * scale, y: y * scale)
    }
}

#Preview("All statuses") {
    let statusStackSpacing: CGFloat = 12
    let renderedSizes: [CGFloat] = [16, 24, 48]
    let statusRowSpacing: CGFloat = 8
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
    VStack(spacing: statusStackSpacing) {
        ForEach(renderedSizes, id: \.self) { size in
            HStack(spacing: statusRowSpacing) {
                ForEach(Array(statuses.enumerated()), id: \.offset) { _, status in
                    TaskStatusIconView(status: status, size: size)
                }
            }
        }
    }
    .padding()
}
