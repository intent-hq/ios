import Lottie
import SwiftUI

/// Full-screen launch splash using the supplied twist intro and pulse loop.
struct SplashArtView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var playback: SplashPlaybackState
    /// Held for the view's lifetime only, so the decoded compositions go away with
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
        scenePhase: ScenePhase, reduceMotion: Bool, hasAnimation: Bool
    ) -> Bool {
        scenePhase == .active && !reduceMotion && hasAnimation
    }

    private var animation: SplashAnimation? { lease?.animation }

    private var shouldAnimate: Bool {
        Self.shouldAnimate(
            scenePhase: scenePhase,
            reduceMotion: reduceMotion,
            hasAnimation: animation != nil
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
                        let sample = animation.frame(at: playback.elapsedTime, animated: !reduceMotion)
                        SplashFrameView(
                            animation: sample.animation,
                            frame: sample.frame,
                            colorScheme: colorScheme
                        )
                        .frame(
                            width: Constants.Splash.maximumLogoDimension,
                            height: Constants.Splash.maximumLogoDimension
                        )
                    }
                }
            }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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

/// Lottie renders the source paths, keyframes and time remapping directly. The
/// existing monotonic clock is the sole playback driver: Lottie never starts an
/// independent animation that could continue while this scene is inactive.
struct SplashFrameView: UIViewRepresentable {
    let animation: LottieAnimation
    let frame: AnimationFrameTime
    let colorScheme: ColorScheme

    func makeUIView(context _: Context) -> LottieAnimationView {
        // The main-thread renderer supports the supplied twist's time remapping
        // and samples exact source frames without Core Animation approximation.
        let view = LottieAnimationView(
            animation: nil,
            configuration: LottieConfiguration(renderingEngine: .mainThread)
        )
        view.contentMode = .scaleAspectFit
        view.backgroundBehavior = .pause
        view.animateLayoutChangesWithCurrentCoreAnimationContext = false
        return view
    }

    func updateUIView(_ view: LottieAnimationView, context _: Context) {
        if view.animation !== animation { view.animation = animation }
        let keypath = AnimationKeypath(keypath: "**.Color")
        let color = UIColor(Theme.foreground(for: colorScheme)).lottieColorValue
        if (view.valueProviders[keypath] as? ColorValueProvider)?.color != color {
            view.setValueProvider(ColorValueProvider(color), keypath: keypath)
        }
        view.currentFrame = frame
    }

    static func dismantleUIView(_ view: LottieAnimationView, coordinator _: ()) {
        view.stop()
        view.animation = nil
    }
}

#Preview("Splash art") {
    SplashArtView()
}

#Preview("Splash art - Dark") {
    SplashArtView()
        .preferredColorScheme(.dark)
}
