import Foundation
@testable import Intent
import Lottie
import SwiftUI
import Testing

/// ios#247 / ios#256: splash playback samples one injectable monotonic clock
/// for both source-frame selection and pause/resume accounting. The decoded
/// compositions live only while a splash owner holds a lease on them.
struct SplashPlaybackTests {
    /// Stepped monotonic clock: nothing but `advance` moves it.
    private final class SteppedClock: SplashPlaybackClock {
        var now: TimeInterval

        init(now: TimeInterval = 100) {
            self.now = now
        }

        func advance(by seconds: TimeInterval) {
            now += seconds
        }
    }

    private final class Counter {
        var count = 0
    }

    private func bundledAnimation() throws -> SplashAnimation {
        try #require(
            SplashAnimation(),
            "The supplied twist and pulse JSON animations must decode from the app bundle"
        )
    }

    // MARK: - Frame selection under a stepped clock

    @Test func twistPlaysOnceThenPulseLoopsOnTheInjectedClock() throws {
        let animation = try bundledAnimation()
        let clock = SteppedClock(now: 0)
        var playback = SplashPlaybackState(clock: clock)
        playback.setRunning(true)

        // Source files: twist is 46 frames, pulse is 61, both at 30 fps.
        // Crossing the 1.2-second loading phase must not restart the intro.
        let samples: [(time: Double, expected: (animation: LottieAnimation, frame: Double))] = [
            (0, (animation.twist, 0)), (0.5, (animation.twist, 15)), (1.2, (animation.twist, 36)),
            (46.0 / 30, (animation.pulse, 0)), (61.0 / 30, (animation.pulse, 15)),
            (122.0 / 30, (animation.pulse, 15)), (183.0 / 30, (animation.pulse, 15))
        ]
        for sample in samples {
            clock.now = sample.time
            let rendered = animation.frame(at: playback.elapsedTime, animated: true)
            #expect(rendered.animation === sample.expected.animation)
            #expect(abs(rendered.frame - sample.expected.frame) < 0.0001)
        }
    }

    /// The clock-jump case: playback moves only when the injected monotonic
    /// clock moves. Real time passing between samples, or a wall-clock (NTP)
    /// adjustment, has no timestamp source to leak in through.
    @Test func elapsedTimeMovesOnlyWithTheInjectedClock() {
        let clock = SteppedClock()
        var playback = SplashPlaybackState(clock: clock)
        playback.setRunning(true)

        #expect(playback.elapsedTime == 0)
        #expect(playback.elapsedTime == 0)
        clock.advance(by: 1.5)
        #expect(playback.elapsedTime == 1.5)
        // The production clock is monotonic and never regresses; should an
        // injected one step backwards, the arithmetic clamps at zero rather
        // than producing a negative playback time.
        clock.advance(by: -10)
        #expect(playback.elapsedTime == 0)
        clock.advance(by: 10)
        #expect(playback.elapsedTime == 1.5)
    }

    // MARK: - Pause / resume

    @Test func pauseExcludesInactiveTimeAndResumeContinuesWithoutReset() {
        let clock = SteppedClock()
        var playback = SplashPlaybackState(clock: clock)
        #expect(!playback.isRunning)
        #expect(playback.elapsedTime == 0)

        playback.setRunning(true)
        clock.advance(by: 0.5)
        #expect(playback.isRunning)
        #expect(playback.elapsedTime == 0.5)

        playback.setRunning(false)
        clock.advance(by: 5)
        #expect(!playback.isRunning)
        #expect(playback.elapsedTime == 0.5)

        // Redundant transitions neither double-count nor restart.
        playback.setRunning(false)
        playback.setRunning(true)
        playback.setRunning(true)
        clock.advance(by: 0.25)
        #expect(playback.elapsedTime == 0.75)
    }

    // MARK: - Reduce Motion

    @Test func reduceMotionSelectsTheCompletePulseMarkAtAnyPlaybackTime() throws {
        let animation = try bundledAnimation()
        for elapsed in [0, 0.5, 1.2, 2, 100] {
            let rendered = animation.frame(at: elapsed, animated: false)
            #expect(rendered.animation === animation.pulse)
            #expect(rendered.frame == 0)
        }
    }

    @Test func reduceMotionAndInactiveScenesPausePlayback() {
        let animates = SplashArtView.shouldAnimate
        #expect(animates(.active, false, true))
        #expect(!animates(.active, true, true))
        #expect(!animates(.inactive, false, true))
        #expect(!animates(.background, false, true))
        #expect(!animates(.active, false, false))
    }

    // MARK: - Composition lifetime

    @Test func compositionsAreDecodedOnceWhileAnyOwnerIsAliveAndReleasedAfterTheLast() throws {
        let loads = Counter()
        let store = SplashAnimationStore {
            loads.count += 1
            return SplashAnimation()
        }
        #expect(!store.isRetainingAnimations)

        var first = store.lease()
        var second = store.lease()
        weak var twist = first?.animation.twist
        weak var pulse = first?.animation.pulse
        #expect(first != nil)
        #expect(first === second)
        #expect(loads.count == 1)
        #expect(store.isRetainingAnimations)

        first = nil
        #expect(store.isRetainingAnimations)
        second = nil
        #expect(!store.isRetainingAnimations)
        #expect(twist == nil)
        #expect(pulse == nil)

        do {
            let third = store.lease()
            withExtendedLifetime(third) {
                #expect(loads.count == 2)
                #expect(store.isRetainingAnimations)
            }
        }
        #expect(!store.isRetainingAnimations)
    }

    @Test func sharedStoreServesTheBundledAnimation() throws {
        let lease = try #require(SplashAnimationStore.shared.lease())
        #expect(lease.animation.twist.size == CGSize(width: 256, height: 256))
        #expect(lease.animation.pulse.size == CGSize(width: 256, height: 256))
        #expect(lease.animation.twist.duration == 46.0 / 30)
        #expect(lease.animation.pulse.duration == 61.0 / 30)
    }
}
