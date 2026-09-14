import SwiftUI

/// Loading phase overlay: the splash GIF itself is rendered by RootView in a
/// position shared with the connecting phase (so playback doesn't reset on the
/// loading → connecting transition). This view only owns the launch timer
/// that advances the coordinator once the intro has had time to play.
struct LoadingView: View {
    @Environment(AppCoordinator.self) var coordinator

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .task {
                // Advance to connecting after a beat. RootView keeps the
                // shared SplashArtView mounted across loading → connecting,
                // so GIF playback continues uninterrupted. Don't lengthen the
                // 1.2-second phase to wait for a complete GIF cycle.
                try? await Task.sleep(for: Constants.Loading.phaseDuration)
                coordinator.onLoadComplete()
            }
    }
}

// MARK: - Intent Logo Shape

/// The Intent burst mark, matching cloudlands-fe's Logo.svelte vector.
struct IntentLogo: Shape {
    private enum Metrics {
        static let viewBoxSize: CGFloat = 24
        static let strokeWidth: CGFloat = 2.06
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        // Original viewBox: 0 0 24 24
        let scaleX = rect.width / Metrics.viewBoxSize
        let scaleY = rect.height / Metrics.viewBoxSize
        let transform = CGAffineTransform(scaleX: scaleX, y: scaleY)

        // These coordinates are intrinsic data from the source artwork; keeping
        // them literal preserves direct comparison with the original path.
        // swiftlint:disable no_magic_numbers
        path.move(to: CGPoint(x: 12, y: 15.82))
        path.addLine(to: CGPoint(x: 12, y: 23.76))

        path.move(to: CGPoint(x: 4.44, y: 21))
        path.addLine(to: CGPoint(x: 8.35, y: 16.35))
        path.addCurve(
            to: CGPoint(x: 6.4, y: 12.99),
            control1: CGPoint(x: 10.16, y: 14.95),
            control2: CGPoint(x: 8.51, y: 12.12)
        )
        path.addLine(to: CGPoint(x: 0.42, y: 14.04))

        path.move(to: CGPoint(x: 1.82, y: 6.12))
        path.addLine(to: CGPoint(x: 7.08, y: 9.16))
        path.addCurve(
            to: CGPoint(x: 10.06, y: 6.66),
            control1: CGPoint(x: 8.77, y: 10.73),
            control2: CGPoint(x: 11.31, y: 8.6)
        )
        path.addLine(to: CGPoint(x: 7.98, y: 0.95))

        path.move(to: CGPoint(x: 16.02, y: 0.95))
        path.addLine(to: CGPoint(x: 13.94, y: 6.66))
        path.addCurve(
            to: CGPoint(x: 16.92, y: 9.16),
            control1: CGPoint(x: 12.69, y: 8.6),
            control2: CGPoint(x: 15.23, y: 10.73)
        )
        path.addLine(to: CGPoint(x: 22.18, y: 6.12))

        path.move(to: CGPoint(x: 23.58, y: 14.04))
        path.addLine(to: CGPoint(x: 17.6, y: 12.99))
        path.addCurve(
            to: CGPoint(x: 15.65, y: 16.35),
            control1: CGPoint(x: 15.49, y: 12.12),
            control2: CGPoint(x: 13.84, y: 14.95)
        )
        path.addLine(to: CGPoint(x: 19.56, y: 21))
        // swiftlint:enable no_magic_numbers

        return path
            .strokedPath(StrokeStyle(lineWidth: Metrics.strokeWidth, lineCap: .butt, lineJoin: .round))
            .applying(transform)
    }
}

#Preview("Loading") {
    ZStack {
        SplashArtView()
        LoadingView()
    }
    .environment(BackendSessionRegistry.shared.makePairingSession().makeCoordinator())
}

#Preview("Loading - Dark") {
    ZStack {
        SplashArtView()
        LoadingView()
    }
    .environment(BackendSessionRegistry.shared.makePairingSession().makeCoordinator())
    .preferredColorScheme(.dark)
}
