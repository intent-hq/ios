import SwiftUI

struct TaskProgressRingView: View {
    private typealias Geometry = Constants.TaskProgressRing

    let stats: TaskStats
    var size: CGFloat = Geometry.defaultSize
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var strokeWidth: CGFloat {
        size * (colorSchemeContrast == .increased
            ? Geometry.increasedStrokeWidth
            : Geometry.standardStrokeWidth) / Geometry.referenceSize
    }

    private var trackColor: Color {
        colorSchemeContrast == .increased ? .primary.opacity(Geometry.increasedTrackOpacity) : Palette.track
    }

    private enum Palette {
        static let track = Constants.Colors.TaskProgress.track
        static let green = Constants.Colors.TaskProgress.complete
        static let blue = Constants.Colors.TaskProgress.inProgress
    }

    var body: some View {
        let completed = stats.total > 0 ? CGFloat(stats.completed) / CGFloat(stats.total) : 0
        let inProgress = stats.total > 0 ? CGFloat(stats.inProgress) / CGFloat(stats.total) : 0
        let diameter = size - strokeWidth

        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: strokeWidth)
                .frame(width: diameter, height: diameter)
            if stats.inProgress > 0 {
                Circle()
                    .trim(from: completed, to: min(completed + inProgress, 1))
                    .stroke(
                        Palette.blue,
                        style: StrokeStyle(
                            lineWidth: strokeWidth,
                            lineCap: .round,
                            dash: differentiateWithoutColor
                                ? [strokeWidth, strokeWidth * Geometry.differentiatedDashMultiplier]
                                : []
                        )
                    )
                    .frame(width: diameter, height: diameter)
            }
            if stats.completed > 0 {
                Circle()
                    .trim(from: 0, to: completed)
                    .stroke(Palette.green, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                    .frame(width: diameter, height: diameter)
            }
        }
        .rotationEffect(Geometry.startAngle)
        .environment(\.layoutDirection, .leftToRight)
        .frame(width: size, height: size)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var text = "\(stats.completed) of \(stats.total) tasks complete"
        if stats.inProgress > 0 {
            text += ", \(stats.inProgress) in progress"
        }
        return text
    }
}

#Preview {
    VStack(spacing: 12) {
        TaskProgressRingView(stats: TaskStats(total: 4, completed: 0, inProgress: 0))
        TaskProgressRingView(stats: TaskStats(total: 4, completed: 1, inProgress: 2))
        TaskProgressRingView(stats: TaskStats(total: 4, completed: 4, inProgress: 0))
        TaskProgressRingView(stats: TaskStats(total: 4, completed: 2, inProgress: 1), size: 28)
    }
    .padding()
}
