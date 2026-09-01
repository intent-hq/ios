import SwiftUI

/// Circular linked-task progress ring matching the fe sidebar's NotesPanel
/// ring: a muted track, a green arc for the completed fraction, and a blue
/// arc for the in-progress fraction drawn immediately after the completed
/// one. Arcs start at 12 o'clock and run clockwise.
struct TaskProgressRingView: View {
    let stats: TaskStats
    var size: CGFloat = 14

    private var strokeWidth: CGFloat { size * 2.5 / 14 }

    private enum Palette {
        // Track: same muted gray as TaskStatusIconView outlines (#99999966).
        static let track = Constants.Colors.TaskProgress.track
        // fe's emerald-500 (#10b981) completed arc.
        static let green = Constants.Colors.TaskProgress.complete
        // In-progress arc: the app's in-progress blue (#00BCFF).
        static let blue = Constants.Colors.TaskProgress.inProgress
    }

    var body: some View {
        let completed = stats.total > 0 ? CGFloat(stats.completed) / CGFloat(stats.total) : 0
        let inProgress = stats.total > 0 ? CGFloat(stats.inProgress) / CGFloat(stats.total) : 0
        let diameter = size - strokeWidth

        ZStack {
            Circle()
                .stroke(Palette.track, lineWidth: strokeWidth)
                .frame(width: diameter, height: diameter)
            if stats.inProgress > 0 {
                Circle()
                    .trim(from: completed, to: min(completed + inProgress, 1))
                    .stroke(Palette.blue, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                    .frame(width: diameter, height: diameter)
            }
            if stats.completed > 0 {
                Circle()
                    .trim(from: 0, to: completed)
                    .stroke(Palette.green, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                    .frame(width: diameter, height: diameter)
            }
        }
        // SwiftUI trims start at 3 o'clock; the fe ring starts at 12.
        .rotationEffect(.degrees(-90))
        // Keep the arc geometry stable under RTL layout mirroring.
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
