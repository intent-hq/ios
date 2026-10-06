import SwiftUI

struct IntentLoadingIndicator: View {
    var size: CGFloat = 24
    var label: LocalizedStringKey = "Loading"
    var playbackMode: SplashAnimation.PlaybackMode = .twistThenPulse
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playback = SplashPlaybackState()
    @State private var lease: SplashAnimationLease?

    private var shouldAnimate: Bool {
        SplashArtView.shouldAnimate(scenePhase: scenePhase, reduceMotion: reduceMotion, hasAnimation: lease != nil)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: lease?.animation.minimumFrameDuration, paused: !shouldAnimate)) { _ in
            if let animation = lease?.animation {
                // Keep the existing intro's paused position; pulse-only loaders rest on the complete mark.
                let animated = playbackMode == .pulse ? shouldAnimate : !reduceMotion
                let sample = animation.frame(at: playback.elapsedTime, animated: animated, mode: playbackMode)
                SplashFrameView(animation: sample.animation, frame: sample.frame, colorScheme: colorScheme)
            } else if playbackMode == .pulse {
                ProgressView()
            } else {
                IntentLogo().fill(Theme.foreground(for: colorScheme))
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .onAppear {
            lease = SplashAnimationStore.shared.lease()
            playback.setRunning(shouldAnimate)
        }
        .onChange(of: shouldAnimate) { _, running in playback.setRunning(running) }
        .onDisappear {
            playback.setRunning(false)
            lease = nil
        }
    }
}
