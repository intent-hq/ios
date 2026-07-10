import SwiftUI

struct AuggieAvatarView: View {
    let seed: String
    var size: CGFloat = 24
    var specialist: String? = nil
    var isActive: Bool = false

    @State private var isPulsing = false

    // The auggie is wider than tall (aspect ratio ~20:12.3)
    private let aspectRatio: CGFloat = 20.0 / 12.3

    private var hue: Double {
        Double(RepoColorSystem.stableHash(seed) % 360) / 360.0
    }

    private var color1: Color {
        Color(hue: hue, saturation: 0.5, brightness: 0.85)
    }

    private var color2: Color {
        Color(hue: (hue + 0.1).truncatingRemainder(dividingBy: 1.0), saturation: 0.6, brightness: 0.7)
    }

    private var width: CGFloat { size }
    private var height: CGFloat { size / aspectRatio }

    var body: some View {
        ZStack {
            // Inner body (colored fill)
            AuggieBodyShape()
                .fill(
                    LinearGradient(
                        colors: [color1, color2],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: width, height: height)

            // Outer bracket frame
            AuggieBracketFrame()
                .fill(Color.black.opacity(0.4))
                .frame(width: width, height: height)

            // Specialist icon or eyes
            if let specialist = specialist {
                specialistIcon(for: specialist)
            } else {
                // Default eyes
                HStack(spacing: width * 0.08) {
                    RoundedRectangle(cornerRadius: width * 0.02)
                        .fill(Color.black.opacity(0.45))
                        .frame(width: width * 0.055, height: height * 0.22)
                    RoundedRectangle(cornerRadius: width * 0.02)
                        .fill(Color.black.opacity(0.45))
                        .frame(width: width * 0.055, height: height * 0.22)
                }
                .offset(y: -height * 0.02)
            }

            // Active pulsing indicator
            if isActive {
                AuggieBodyShape()
                    .stroke(Color.green.opacity(isPulsing ? 0.6 : 0.2), lineWidth: 1.5)
                    .frame(width: width, height: height)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isPulsing)
                    .onAppear { isPulsing = true }
            }
        }
        .frame(width: width, height: height)
    }

    @ViewBuilder
    private func specialistIcon(for type: String) -> some View {
        let iconSize = width * 0.4
        switch type {
        case "spec-writer":
            // Coordinator: 3 horizontal lines
            VStack(spacing: height * 0.08) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(Color.black.opacity(0.45))
                        .frame(width: iconSize, height: max(1, height * 0.045))
                }
            }
        case "implementor":
            // Implementor: I-beam
            ZStack {
                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: max(1, height * 0.045), height: iconSize * 0.8)
                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: iconSize * 0.6, height: max(1, height * 0.045))
                    .offset(y: -iconSize * 0.35)
                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: iconSize * 0.6, height: max(1, height * 0.045))
                    .offset(y: iconSize * 0.35)
            }
        case "verifier":
            // Verifier: checkmark
            Path { path in
                let startX = width * 0.35
                let startY = height * 0.45
                path.move(to: CGPoint(x: startX, y: startY))
                path.addLine(to: CGPoint(x: width * 0.45, y: height * 0.6))
                path.addLine(to: CGPoint(x: width * 0.65, y: height * 0.3))
            }
            .stroke(Color.black.opacity(0.45), style: StrokeStyle(
                lineWidth: max(1, width * 0.04), lineCap: .round, lineJoin: .round))
        case "developer":
            // Developer: lightning bolt
            Path { path in
                path.move(to: CGPoint(x: width * 0.55, y: height * 0.15))
                path.addLine(to: CGPoint(x: width * 0.42, y: height * 0.5))
                path.addLine(to: CGPoint(x: width * 0.55, y: height * 0.5))
                path.addLine(to: CGPoint(x: width * 0.45, y: height * 0.85))
            }
            .stroke(Color.black.opacity(0.45), style: StrokeStyle(
                lineWidth: max(1, width * 0.035), lineCap: .round, lineJoin: .round))
        case "pr-reviewer":
            // PR Reviewer: magnifying glass
            ZStack {
                Circle()
                    .stroke(Color.black.opacity(0.45), lineWidth: max(1, width * 0.035))
                    .frame(width: iconSize * 0.5, height: iconSize * 0.5)
                    .offset(x: -iconSize * 0.08, y: -iconSize * 0.08)
                Path { path in
                    path.move(to: CGPoint(x: width * 0.55, y: height * 0.55))
                    path.addLine(to: CGPoint(x: width * 0.65, y: height * 0.7))
                }
                .stroke(Color.black.opacity(0.45), style: StrokeStyle(
                    lineWidth: max(1, width * 0.035), lineCap: .round))
            }
        default:
            // Unknown specialist: show eyes
            HStack(spacing: width * 0.08) {
                RoundedRectangle(cornerRadius: width * 0.02)
                    .fill(Color.black.opacity(0.45))
                    .frame(width: width * 0.055, height: height * 0.22)
                RoundedRectangle(cornerRadius: width * 0.02)
                    .fill(Color.black.opacity(0.45))
                    .frame(width: width * 0.055, height: height * 0.22)
            }
        }
    }
}

/// The inner body of the Auggie — a rounded rectangle with pinched sides
/// Based on the Electron SVG inner fill path
struct AuggieBodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 20.0
        let sy = rect.height / 12.3

        var path = Path()

        let inset: CGFloat = 2.93 * sx
        let top: CGFloat = 0.0
        let bottom = rect.height
        let cornerR: CGFloat = 0.7 * min(sx, sy)
        let pinchDepth: CGFloat = 1.86 * sx
        let midY = rect.height / 2.0

        let left = inset
        let right = rect.width - inset

        path.move(to: CGPoint(x: left + cornerR, y: top))
        path.addLine(to: CGPoint(x: right - cornerR, y: top))
        path.addQuadCurve(to: CGPoint(x: right, y: top + cornerR),
                          control: CGPoint(x: right, y: top))
        path.addCurve(
            to: CGPoint(x: right + pinchDepth, y: midY),
            control1: CGPoint(x: right, y: midY * 0.55),
            control2: CGPoint(x: right + pinchDepth, y: midY * 0.7))
        path.addCurve(
            to: CGPoint(x: right, y: bottom - cornerR),
            control1: CGPoint(x: right + pinchDepth, y: midY * 1.3),
            control2: CGPoint(x: right, y: midY * 1.45))
        path.addQuadCurve(to: CGPoint(x: right - cornerR, y: bottom),
                          control: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: left + cornerR, y: bottom))
        path.addQuadCurve(to: CGPoint(x: left, y: bottom - cornerR),
                          control: CGPoint(x: left, y: bottom))
        path.addCurve(
            to: CGPoint(x: left - pinchDepth, y: midY),
            control1: CGPoint(x: left, y: midY * 1.45),
            control2: CGPoint(x: left - pinchDepth, y: midY * 1.3))
        path.addCurve(
            to: CGPoint(x: left, y: top + cornerR),
            control1: CGPoint(x: left - pinchDepth, y: midY * 0.7),
            control2: CGPoint(x: left, y: midY * 0.55))
        path.addQuadCurve(to: CGPoint(x: left + cornerR, y: top),
                          control: CGPoint(x: left, y: top))

        path.closeSubpath()
        return path
    }
}

/// The outer bracket frame `{ }` of the Auggie
/// Based on the Electron SVG frame path
struct AuggieBracketFrame: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 20.0
        let sy = rect.height / 12.3
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x * sx, y: (y - 1.0) * sy)
        }

        var path = Path()

        // Left bracket {
        path.move(to: pt(7.64, 0.5))
        path.addCurve(to: pt(8.42, 1.285),
                      control1: pt(8.048, 0.583), control2: pt(8.425, 1.077))
        path.addCurve(to: pt(8.07, 1.841),
                      control1: pt(8.425, 1.493), control2: pt(8.342, 1.694))
        path.addCurve(to: pt(7.64, 2.071),
                      control1: pt(7.923, 1.988), control2: pt(7.848, 2.071))
        path.addLine(to: pt(3.788, 2.071))
        path.addLine(to: pt(3.788, 4.994))
        path.addCurve(to: pt(2.938, 6.996),
                      control1: pt(3.788, 5.778), control2: pt(3.461, 6.487))
        path.addCurve(to: pt(3.787, 9.003),
                      control1: pt(3.463, 7.505), control2: pt(3.787, 8.218))
        path.addLine(to: pt(3.788, 11.408))
        path.addLine(to: pt(3.788, 11.928))
        path.addLine(to: pt(7.64, 11.928))
        path.addCurve(to: pt(8.426, 12.714),
                      control1: pt(7.848, 11.928), control2: pt(8.193, 12.011))
        path.addCurve(to: pt(8.07, 13.27),
                      control1: pt(8.426, 12.922), control2: pt(8.343, 13.122))
        path.addCurve(to: pt(7.64, 13.5),
                      control1: pt(7.923, 13.417), control2: pt(7.848, 13.5))
        path.addLine(to: pt(3.703, 13.5))
        path.addCurve(to: pt(2.216, 12.012),
                      control1: pt(2.883, 13.5), control2: pt(2.216, 12.833))
        path.addLine(to: pt(2.216, 9.004))
        path.addCurve(to: pt(1.891, 8.172),
                      control1: pt(2.216, 8.696), control2: pt(2.099, 8.398))
        path.addCurve(to: pt(1.086, 7.783),
                      control1: pt(1.681, 7.946), control2: pt(1.393, 7.807))
        path.addCurve(to: pt(0.575, 7.528),
                      control1: pt(0.887, 7.764), control2: pt(0.706, 7.673))
        path.addCurve(to: pt(0.371, 7.0),
                      control1: pt(0.444, 7.384), control2: pt(0.371, 7.195))
        path.addCurve(to: pt(0.575, 6.472),
                      control1: pt(0.371, 6.805), control2: pt(0.444, 6.616))
        path.addCurve(to: pt(1.086, 6.218),
                      control1: pt(0.706, 6.327), control2: pt(0.887, 6.237))
        path.addCurve(to: pt(1.891, 5.827),
                      control1: pt(1.393, 6.193), control2: pt(1.681, 6.054))
        path.addCurve(to: pt(2.216, 4.995),
                      control1: pt(2.074, 5.629), control2: pt(2.185, 5.377))
        path.addLine(to: pt(2.216, 1.987))
        path.addCurve(to: pt(3.703, 0.5),
                      control1: pt(2.216, 1.187), control2: pt(2.883, 0.5))
        path.closeSubpath()

        // Right bracket }
        path.move(to: pt(16.547, 0.5))
        path.addCurve(to: pt(18.034, 1.987),
                      control1: pt(17.367, 0.5), control2: pt(18.034, 1.187))
        path.addLine(to: pt(18.034, 4.995))
        path.addCurve(to: pt(18.359, 5.827),
                      control1: pt(18.04, 5.377), control2: pt(18.176, 5.629))
        path.addCurve(to: pt(19.164, 6.218),
                      control1: pt(18.569, 6.054), control2: pt(18.857, 6.193))
        path.addCurve(to: pt(19.675, 6.472),
                      control1: pt(19.363, 6.237), control2: pt(19.544, 6.327))
        path.addCurve(to: pt(19.879, 7.0),
                      control1: pt(19.806, 6.616), control2: pt(19.879, 6.805))
        path.addCurve(to: pt(19.675, 7.528),
                      control1: pt(19.879, 7.195), control2: pt(19.806, 7.384))
        path.addCurve(to: pt(19.164, 7.783),
                      control1: pt(19.544, 7.673), control2: pt(19.363, 7.764))
        path.addCurve(to: pt(18.36, 8.172),
                      control1: pt(18.857, 7.807), control2: pt(18.569, 7.946))
        path.addCurve(to: pt(18.034, 9.004),
                      control1: pt(18.151, 8.398), control2: pt(18.034, 8.696))
        path.addLine(to: pt(18.034, 12.012))
        path.addCurve(to: pt(16.547, 13.5),
                      control1: pt(18.034, 12.833), control2: pt(17.367, 13.5))
        path.addLine(to: pt(12.61, 13.5))
        path.addCurve(to: pt(11.824, 12.714),
                      control1: pt(12.402, 13.5), control2: pt(12.055, 13.417))
        path.addCurve(to: pt(12.055, 12.158),
                      control1: pt(11.699, 12.505), control2: pt(11.782, 12.306))
        path.addCurve(to: pt(12.61, 11.928),
                      control1: pt(12.202, 12.011), control2: pt(12.402, 11.928))
        path.addLine(to: pt(16.462, 11.928))
        path.addLine(to: pt(16.462, 11.408))
        path.addLine(to: pt(16.463, 9.003))
        path.addCurve(to: pt(17.313, 6.996),
                      control1: pt(17.463, 8.218), control2: pt(16.787, 7.505))
        path.addCurve(to: pt(16.462, 4.994),
                      control1: pt(16.789, 6.487), control2: pt(16.462, 5.778))
        path.addLine(to: pt(16.462, 2.071))
        path.addLine(to: pt(12.61, 2.071))
        path.addCurve(to: pt(11.825, 1.285),
                      control1: pt(12.402, 2.071), control2: pt(12.077, 1.988))
        path.addCurve(to: pt(11.93, 0.731),
                      control1: pt(11.7, 1.494), control2: pt(11.783, 0.878))
        path.addCurve(to: pt(12.61, 0.5),
                      control1: pt(12.077, 0.583), control2: pt(12.402, 0.5))
        path.closeSubpath()

        return path
    }
}
