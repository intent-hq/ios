import SwiftUI

/// Compact circular task status indicator, visually matching the desktop
/// frontend's `TaskStatusIcon.svelte`:
/// - notStarted / unknown: empty gray outline circle
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

    /// Scale factor from the 24×24 reference space to the rendered size.
    private var s: CGFloat { size / 24 }

    private enum Palette {
        // #99999966
        static let gray = Color(red: 0.6, green: 0.6, blue: 0.6).opacity(0.4)
        // #f59e0b
        static let amber = Color(red: 0xF5 / 255, green: 0x9E / 255, blue: 0x0B / 255)
        // #ef4444
        static let red = Color(red: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255)
        // #00BCFF
        static let skyBlue = Color(red: 0x00 / 255, green: 0xBC / 255, blue: 0xFF / 255)
        // #3b82f6
        static let blue = Color(red: 0x3B / 255, green: 0x82 / 255, blue: 0xF6 / 255)
        // #22c55e
        static let greenStroke = Color(red: 0x22 / 255, green: 0xC5 / 255, blue: 0x5E / 255)
        // #00BD7D
        static let greenFill = Color(red: 0x00 / 255, green: 0xBD / 255, blue: 0x7D / 255)
    }

    /// Outline stroke color per status.
    private var strokeColor: Color {
        switch status {
        case .notStarted, .waiting, .cancelled, .unknown: return Palette.gray
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
                .stroke(strokeColor, lineWidth: 2.5 * s)
                .frame(width: 21.6 * s, height: 21.6 * s)
            if status == .inProgress {
                // fe draws an extra inner ring (r=10, width 2) that thickens
                // the in-progress outline inward.
                Circle()
                    .stroke(strokeColor, lineWidth: 2 * s)
                    .frame(width: 20 * s, height: 20 * s)
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
            .frame(width: radius * 2 * s, height: radius * 2 * s)
        if status == .inProgress {
            // Half fill: only the part right of x = 11.52 (48% of 24) is visible.
            // The fill circle spans x ∈ [12 − radius, 12 + radius]. The mask is
            // pinned to LTR so the visible half never flips under RTL (the fe
            // clip is an absolute x=48% rect).
            circle.mask(
                Rectangle()
                    .padding(.leading, (11.52 - (12 - radius)) * s)
                    .environment(\.layoutDirection, .leftToRight)
            )
        } else {
            circle
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch status {
        case .notStarted, .inProgress, .unknown:
            EmptyView()
        case .waiting:
            Image(systemName: "clock")
                .font(.system(size: 11 * s, weight: .medium))
                .foregroundStyle(Palette.gray)
        case .discussionNeeded:
            Image(systemName: "questionmark")
                .font(.system(size: 12 * s, weight: .bold))
                .foregroundStyle(.white)
        case .blocked:
            Path { p in
                p.move(to: point(12, 5.5))
                p.addLine(to: point(12, 13.5))
            }
            .stroke(.white, style: StrokeStyle(lineWidth: 3 * s, lineCap: .round))
            Circle()
                .fill(.white)
                .frame(width: 3.2 * s, height: 3.2 * s)
                .offset(y: 5.5 * s)
        case .reviewRequired:
            Image(systemName: "eye.fill")
                .font(.system(size: 10 * s, weight: .regular))
                .foregroundStyle(.white)
        case .complete:
            Path { p in
                p.move(to: point(7, 12.5))
                p.addLine(to: point(10.5, 16))
                p.addLine(to: point(17, 9))
            }
            .stroke(.white, style: StrokeStyle(lineWidth: 3.5 * s, lineCap: .round, lineJoin: .round))
        case .cancelled:
            Path { p in
                p.move(to: point(5, 19))
                p.addLine(to: point(19, 5))
            }
            .stroke(Palette.gray, style: StrokeStyle(lineWidth: 2.5 * s, lineCap: .round))
        }
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * s, y: y * s)
    }
}

#Preview("All statuses") {
    let statuses: [TaskDisplayStatus] = [
        .notStarted, .waiting, .discussionNeeded, .blocked, .inProgress,
        .reviewRequired, .complete, .cancelled, .unknown,
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
