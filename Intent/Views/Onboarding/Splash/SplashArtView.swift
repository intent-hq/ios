import SwiftUI

/// Full-screen launch splash using the supplied GIF's frames and timing.
struct SplashArtView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var playback: SplashPlaybackState
    /// Held for the view's lifetime only, so the decoded frames go away with
    /// the splash (ios#256).
    @State private var lease: SplashAnimationLease?

    private let store: SplashAnimationStore

    init(
        clock: any SplashPlaybackClock = MediaTimeSplashClock(),
        store: SplashAnimationStore = .shared
    ) {
        self.store = store
        _playback = State(initialValue: SplashPlaybackState(clock: clock))
        _lease = State(initialValue: store.lease())
    }

    static func shouldAnimate(
        scenePhase: ScenePhase, reduceMotion: Bool, frameCount: Int
    ) -> Bool {
        scenePhase == .active && !reduceMotion && frameCount > 1
    }

    private var animation: SplashAnimation? { lease?.animation }

    private var shouldAnimate: Bool {
        Self.shouldAnimate(
            scenePhase: scenePhase,
            reduceMotion: reduceMotion,
            frameCount: animation?.frameCount ?? 0
        )
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
                                at: playback.elapsedTime,
                                animated: !reduceMotion
                            ),
                            colorScheme: colorScheme
                        )
                    }
                }
            }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            if lease == nil { lease = store.lease() }
            playback.setRunning(shouldAnimate)
        }
        .onChange(of: shouldAnimate) { _, isRunning in
            playback.setRunning(isRunning)
        }
        .onDisappear {
            playback.setRunning(false)
            lease = nil
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
                    .scaledToFit()
                    // The source is an opaque black-on-white GIF. Inverting
                    // before deriving alpha keeps only the mark, including its
                    // antialiased gray edge coverage, without pixel processing.
                    .colorInvert()
                    .luminanceToAlpha()
            }
            .frame(
                maxWidth: Constants.Splash.maximumLogoDimension,
                maxHeight: Constants.Splash.maximumLogoDimension
            )
    }
}

#Preview("Splash art") {
    SplashArtView()
}

#Preview("Splash art - Dark") {
    SplashArtView()
        .preferredColorScheme(.dark)
}
