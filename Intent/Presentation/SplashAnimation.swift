import Foundation
import Lottie

struct SplashAnimation {
    enum PlaybackMode {
        case twistThenPulse
        case pulse
        case twistLoop
    }

    let twist: LottieAnimation
    let pulse: LottieAnimation

    var minimumFrameDuration: TimeInterval { 1 / max(twist.framerate, pulse.framerate) }

    init?(bundle: Bundle = .main) {
        guard
            let twist = LottieAnimation.named(
                "intent_mark_twist_256", bundle: bundle, animationCache: nil
            ),
            let pulse = LottieAnimation.named(
                "intent_mark_pulse_256", bundle: bundle, animationCache: nil
            ),
            twist.duration > 0, pulse.duration > 0,
            twist.framerate > 0, pulse.framerate > 0
        else { return nil }
        self.twist = twist
        self.pulse = pulse
    }

    func frame(
        at elapsedTime: TimeInterval, animated: Bool, mode: PlaybackMode = .twistThenPulse
    ) -> (animation: LottieAnimation, frame: AnimationFrameTime) {
        guard animated else { return (pulse, pulse.startFrame) }
        let elapsed = elapsedTime.isFinite ? max(0, elapsedTime) : 0
        if mode == .twistLoop {
            let loopTime = elapsed.truncatingRemainder(dividingBy: twist.duration)
            let firstVisibleFrame = twist.startFrame + 1
            return (twist, max(firstVisibleFrame, twist.frameTime(forTime: loopTime)))
        }
        let introDuration = mode == .twistThenPulse ? twist.duration : 0
        if elapsed < introDuration {
            return (twist, twist.frameTime(forTime: elapsed))
        }
        let loopTime = (elapsed - introDuration).truncatingRemainder(dividingBy: pulse.duration)
        return (pulse, pulse.frameTime(forTime: loopTime))
    }
}

final class SplashAnimationLease {
    let animation: SplashAnimation

    init(animation: SplashAnimation) {
        self.animation = animation
    }
}

final class SplashAnimationStore {
    static let shared = SplashAnimationStore { SplashAnimation() }

    private let load: () -> SplashAnimation?
    private weak var current: SplashAnimationLease?

    init(load: @escaping () -> SplashAnimation?) {
        self.load = load
    }

    var isRetainingAnimations: Bool { current != nil }

    func lease() -> SplashAnimationLease? {
        if let current { return current }
        guard let animation = load() else { return nil }
        let lease = SplashAnimationLease(animation: animation)
        current = lease
        return lease
    }
}
