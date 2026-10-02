import SwiftUI

struct IntentLoadingIndicator: View {
    var size: CGFloat = 24
    var label: LocalizedStringKey = "Loading"
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
                let sample = animation.frame(at: playback.elapsedTime, animated: !reduceMotion)
                SplashFrameView(animation: sample.animation, frame: sample.frame, colorScheme: colorScheme)
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
