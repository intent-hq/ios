import Foundation
import Lottie

/// The supplied compositions, decoded without Lottie's process-wide cache so
/// their lifetime remains bounded by the visible splash's lease (ios#256).
struct SplashAnimation {
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

    /// Play the entire twist once, then loop pulse using each JSON's own timing.
    /// Pulse's first frame is a complete mark; twist's first frame is empty.
    func frame(
        at elapsedTime: TimeInterval, animated: Bool
    ) -> (animation: LottieAnimation, frame: AnimationFrameTime) {
        guard animated else { return (pulse, pulse.startFrame) }
        let elapsed = elapsedTime.isFinite ? max(0, elapsedTime) : 0
        if elapsed < twist.duration {
            return (twist, twist.frameTime(forTime: elapsed))
        }
        let loopTime = (elapsed - twist.duration).truncatingRemainder(dividingBy: pulse.duration)
        return (pulse, pulse.frameTime(forTime: loopTime))
    }
}

/// Keeps one decoded `SplashAnimation` alive for as long as the owner holds it.
final class SplashAnimationLease {
    let animation: SplashAnimation

    init(animation: SplashAnimation) {
        self.animation = animation
    }
}

/// Bounds the decoded compositions' lifetime to their owners (ios#256): concurrent
/// owners share one decode, and the compositions are released with the last lease
/// instead of living for the whole process.
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
