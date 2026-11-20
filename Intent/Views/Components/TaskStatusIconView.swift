import SwiftUI

struct TaskStatusIconView: View {
    let status: TaskDisplayStatus
    var size: CGFloat = Metrics.defaultSize
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private typealias Metrics = Constants.TaskStatusIcon

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

    enum Palette {
        static let gray = Constants.Colors.TaskStatus.neutral
        static let amber = Constants.Colors.TaskStatus.warning
        static let red = Constants.Colors.TaskStatus.blocked
        static let skyBlue = Constants.Colors.TaskStatus.inProgress
        static let blue = Constants.Colors.TaskStatus.reviewRequired
        static let greenStroke = Constants.Colors.TaskStatus.completeStroke
        static let greenFill = Constants.Colors.TaskStatus.completeFill
    }

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
            Image(.historyCircle3)
                .resizable()
                .scaledToFit()
                .frame(width: Metrics.secondaryGlyphSize * scale, height: Metrics.secondaryGlyphSize * scale)
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
            Image(.eye)
                .resizable()
                .scaledToFit()
                .frame(width: Metrics.eyeGlyphSize * scale, height: Metrics.eyeGlyphSize * scale)
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
