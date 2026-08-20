import SwiftUI

/// Loading phase overlay: the splash art itself is rendered by RootView in a
/// position shared with the connecting phase (so it doesn't reset on the
/// loading → connecting transition). This view only owns the launch timer
/// that advances the coordinator once the intro has had time to play.
struct LoadingView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .task {
                // Advance to connecting after a beat. This timer (1.2s) is
                // intentionally shorter than the 2.2s intro reveal: RootView
                // keeps the shared SplashArtView mounted across loading →
                // connecting, so the intro keeps playing uninterrupted after
                // the phase change — don't lengthen this to "wait out" the
                // intro.
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                coordinator.onLoadComplete()
            }
    }
}

// MARK: - Intent Logo Shape

/// The Intent logo, converted from the SVG path in src/app.html
struct IntentLogo: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        // Original viewBox: 0 0 33 28
        let scaleX = rect.width / 33.0
        let scaleY = rect.height / 28.0
        let transform = CGAffineTransform(scaleX: scaleX, y: scaleY)

        // Left bracket
        let leftBracket = Path { p in
            p.move(to: CGPoint(x: 5.84, y: 6.94))
            p.addLine(to: CGPoint(x: 12.11, y: 6.94))
            p.addCurve(to: CGPoint(x: 13.14, y: 7.89),
                       control1: CGPoint(x: 12.63, y: 6.94),
                       control2: CGPoint(x: 13.14, y: 7.39))
            p.addCurve(to: CGPoint(x: 12.20, y: 8.85),
                       control1: CGPoint(x: 13.14, y: 8.37),
                       control2: CGPoint(x: 12.71, y: 8.85))
            p.addLine(to: CGPoint(x: 6.38, y: 8.85))
            p.addCurve(to: CGPoint(x: 5.58, y: 9.69),
                       control1: CGPoint(x: 5.90, y: 8.85),
                       control2: CGPoint(x: 5.58, y: 9.16))
            p.addLine(to: CGPoint(x: 5.58, y: 15.01))
            p.addCurve(to: CGPoint(x: 4.46, y: 17.35),
                       control1: CGPoint(x: 5.58, y: 15.95),
                       control2: CGPoint(x: 5.15, y: 16.77))
            p.addCurve(to: CGPoint(x: 5.58, y: 19.90),
                       control1: CGPoint(x: 5.15, y: 17.93),
                       control2: CGPoint(x: 5.58, y: 18.85))
            p.addLine(to: CGPoint(x: 5.58, y: 25.24))
            p.addCurve(to: CGPoint(x: 6.38, y: 26.08),
                       control1: CGPoint(x: 5.58, y: 25.77),
                       control2: CGPoint(x: 5.90, y: 26.08))
            p.addLine(to: CGPoint(x: 12.20, y: 26.08))
            p.addCurve(to: CGPoint(x: 13.14, y: 27.04),
                       control1: CGPoint(x: 12.71, y: 26.08),
                       control2: CGPoint(x: 13.14, y: 26.56))
            p.addCurve(to: CGPoint(x: 12.11, y: 27.99),
                       control1: CGPoint(x: 13.14, y: 27.53),
                       control2: CGPoint(x: 12.63, y: 27.99))
            p.addLine(to: CGPoint(x: 5.63, y: 27.99))
            p.addCurve(to: CGPoint(x: 3.26, y: 25.40),
                       control1: CGPoint(x: 4.28, y: 27.99),
                       control2: CGPoint(x: 3.26, y: 27.10))
            p.addLine(to: CGPoint(x: 3.26, y: 20.11))
            p.addCurve(to: CGPoint(x: 1.70, y: 18.43),
                       control1: CGPoint(x: 3.26, y: 19.07),
                       control2: CGPoint(x: 2.72, y: 18.45))
            p.addCurve(to: CGPoint(x: 0.82, y: 17.45),
                       control1: CGPoint(x: 1.17, y: 18.43),
                       control2: CGPoint(x: 0.82, y: 17.97))
            p.addCurve(to: CGPoint(x: 1.70, y: 16.47),
                       control1: CGPoint(x: 0.82, y: 16.93),
                       control2: CGPoint(x: 1.17, y: 16.49))
            p.addCurve(to: CGPoint(x: 3.26, y: 14.82),
                       control1: CGPoint(x: 2.72, y: 16.46),
                       control2: CGPoint(x: 3.26, y: 15.83))
            p.addLine(to: CGPoint(x: 3.26, y: 9.53))
            p.addCurve(to: CGPoint(x: 5.84, y: 6.94),
                       control1: CGPoint(x: 3.26, y: 7.82),
                       control2: CGPoint(x: 4.28, y: 6.94))
            p.closeSubpath()
        }
        path.addPath(leftBracket.applying(transform))

        // Right bracket (mirror of left)
        let rightBracket = Path { p in
            p.move(to: CGPoint(x: 27.47, y: 6.94))
            p.addLine(to: CGPoint(x: 21.20, y: 6.94))
            p.addCurve(to: CGPoint(x: 20.17, y: 7.89),
                       control1: CGPoint(x: 20.68, y: 6.94),
                       control2: CGPoint(x: 20.17, y: 7.39))
            p.addCurve(to: CGPoint(x: 21.11, y: 8.84),
                       control1: CGPoint(x: 20.17, y: 8.37),
                       control2: CGPoint(x: 20.60, y: 8.84))
            p.addLine(to: CGPoint(x: 26.93, y: 8.84))
            p.addCurve(to: CGPoint(x: 27.73, y: 9.69),
                       control1: CGPoint(x: 27.41, y: 8.84),
                       control2: CGPoint(x: 27.73, y: 9.16))
            p.addLine(to: CGPoint(x: 27.73, y: 15.00))
            p.addCurve(to: CGPoint(x: 28.85, y: 17.34),
                       control1: CGPoint(x: 27.73, y: 15.95),
                       control2: CGPoint(x: 28.16, y: 16.77))
            p.addCurve(to: CGPoint(x: 27.73, y: 19.90),
                       control1: CGPoint(x: 28.16, y: 17.93),
                       control2: CGPoint(x: 27.73, y: 18.85))
            p.addLine(to: CGPoint(x: 27.73, y: 25.24))
            p.addCurve(to: CGPoint(x: 26.93, y: 26.08),
                       control1: CGPoint(x: 27.73, y: 25.77),
                       control2: CGPoint(x: 27.41, y: 26.08))
            p.addLine(to: CGPoint(x: 21.11, y: 26.08))
            p.addCurve(to: CGPoint(x: 20.17, y: 27.03),
                       control1: CGPoint(x: 20.60, y: 26.08),
                       control2: CGPoint(x: 20.17, y: 26.56))
            p.addCurve(to: CGPoint(x: 21.20, y: 27.99),
                       control1: CGPoint(x: 20.17, y: 27.53),
                       control2: CGPoint(x: 20.68, y: 27.99))
            p.addLine(to: CGPoint(x: 27.47, y: 27.99))
            p.addCurve(to: CGPoint(x: 30.05, y: 25.39),
                       control1: CGPoint(x: 29.03, y: 27.99),
                       control2: CGPoint(x: 30.05, y: 27.10))
            p.addLine(to: CGPoint(x: 30.05, y: 20.10))
            p.addCurve(to: CGPoint(x: 31.61, y: 18.42),
                       control1: CGPoint(x: 30.05, y: 19.07),
                       control2: CGPoint(x: 30.59, y: 18.44))
            p.addCurve(to: CGPoint(x: 32.49, y: 17.45),
                       control1: CGPoint(x: 32.14, y: 18.42),
                       control2: CGPoint(x: 32.49, y: 17.97))
            p.addCurve(to: CGPoint(x: 31.61, y: 16.47),
                       control1: CGPoint(x: 32.49, y: 16.93),
                       control2: CGPoint(x: 32.14, y: 16.49))
            p.addCurve(to: CGPoint(x: 30.05, y: 14.81),
                       control1: CGPoint(x: 30.59, y: 16.46),
                       control2: CGPoint(x: 30.05, y: 15.83))
            p.addLine(to: CGPoint(x: 30.05, y: 9.52))
            p.addCurve(to: CGPoint(x: 27.47, y: 6.94),
                       control1: CGPoint(x: 30.05, y: 7.82),
                       control2: CGPoint(x: 29.03, y: 6.94))
            p.closeSubpath()
        }
        path.addPath(rightBracket.applying(transform))

        // Left dot
        let leftDot = Path { p in
            let center = CGPoint(x: 11.24, y: 17.42)
            let radius: CGFloat = 2.28
            p.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                     width: radius * 2, height: radius * 2))
        }
        path.addPath(leftDot.applying(transform))

        // Right dot
        let rightDot = Path { p in
            let center = CGPoint(x: 22.55, y: 17.42)
            let radius: CGFloat = 2.28
            p.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                     width: radius * 2, height: radius * 2))
        }
        path.addPath(rightDot.applying(transform))

        // Top pins
        let pinWidth: CGFloat = 1.4
        let pinHeight: CGFloat = 5.4
        let pinRadius: CGFloat = 0.7

        // Top-left pin
        path.addPath(Path(roundedRect: CGRect(x: 15.06 - pinWidth / 2, y: 0.54,
                                               width: pinWidth, height: pinHeight),
                          cornerRadius: pinRadius).applying(transform))

        // Top-right pin
        path.addPath(Path(roundedRect: CGRect(x: 18.42 - pinWidth / 2, y: 0.54,
                                               width: pinWidth, height: pinHeight),
                          cornerRadius: pinRadius).applying(transform))

        return path
    }
}

#Preview("Loading") {
    ZStack {
        SplashArtView()
        LoadingView()
    }
}

#Preview("Loading - Dark") {
    ZStack {
        SplashArtView()
        LoadingView()
    }
    .preferredColorScheme(.dark)
}
