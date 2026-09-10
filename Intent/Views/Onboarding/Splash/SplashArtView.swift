import QuartzCore
import SwiftUI

/// Full-screen launch splash using the supplied GIF's frames and timing.
struct SplashArtView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var playback = SplashPlaybackState()

    private let animation = SplashAnimation.bundled

    private var shouldAnimate: Bool {
        scenePhase == .active && !reduceMotion && (animation?.frameCount ?? 0) > 1
    }

    var body: some View {
        Theme.background(for: colorScheme)
            .overlay {
                TimelineView(.animation(
                    minimumInterval: animation?.minimumFrameDuration,
                    paused: !shouldAnimate
                )) { _ in
                    if let animation {
                        SplashFrameView(
                            image: animation.image(
                                at: playback.elapsedTime(at: CACurrentMediaTime()),
                                animated: !reduceMotion),
                            colorScheme: colorScheme)
                    }
                }
            }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            playback.setRunning(shouldAnimate, at: CACurrentMediaTime())
        }
        .onChange(of: shouldAnimate) { _, isRunning in
            playback.setRunning(isRunning, at: CACurrentMediaTime())
        }
        .onDisappear {
            playback.setRunning(false, at: CACurrentMediaTime())
        }
    }
}

/// Renders the GIF's dark mark as theme foreground without its opaque white canvas.
struct SplashFrameView: View {
    let image: CGImage
    let colorScheme: ColorScheme

    var body: some View {
        Theme.foreground(for: colorScheme)
            .mask {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    // The source is an opaque black-on-white GIF. Inverting
                    // before deriving alpha keeps only the mark, including its
                    // antialiased gray edge coverage, without pixel processing.
                    .colorInvert()
                    .luminanceToAlpha()
            }
            .frame(
                maxWidth: Constants.Splash.maximumLogoDimension,
                maxHeight: Constants.Splash.maximumLogoDimension)
    }
}

#Preview("Splash art") {
    SplashArtView()
}

#Preview("Splash art - Dark") {
    SplashArtView()
        .preferredColorScheme(.dark)
}
