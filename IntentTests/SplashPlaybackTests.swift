import Foundation
import SwiftUI
import Testing
@testable import Intent

/// ios#247 / ios#256: splash playback samples one injectable monotonic clock
/// for both frame selection and pause/resume accounting, and the decoded GIF
/// frames live only while a splash owner holds a lease on them.
struct SplashPlaybackTests {
    /// Stepped monotonic clock: nothing but `advance` moves it.
    private final class SteppedClock: SplashPlaybackClock {
        var now: TimeInterval
        init(now: TimeInterval = 100) { self.now = now }
        func advance(by seconds: TimeInterval) { now += seconds }
    }

    private final class Counter {
        var count = 0
    }

    private func bundledAnimation() throws -> SplashAnimation {
        let url = try #require(
            SplashAnimation.bundledURL, "IntentSplash.gif is missing from the app bundle")
        return try #require(SplashAnimation(url: url))
    }

    /// Playback time in the middle of frame `index`, from the GIF's own timing.
    private func midpoint(ofFrame index: Int, in animation: SplashAnimation) -> TimeInterval {
        animation.frameDurations.prefix(index).reduce(0, +) + animation.frameDurations[index] / 2
    }

    // MARK: - Frame selection under a stepped clock

    @Test func frameIndexFollowsTheInjectedClock() throws {
        let animation = try bundledAnimation()
        try #require(animation.frameCount > 3)
        let clock = SteppedClock()
        var playback = SplashPlaybackState(clock: clock)
        playback.setRunning(true)

        #expect(animation.frameIndex(at: playback.elapsedTime, animated: true) == 0)
        clock.advance(by: midpoint(ofFrame: 1, in: animation))
        #expect(animation.frameIndex(at: playback.elapsedTime, animated: true) == 1)
        clock.advance(by: midpoint(ofFrame: 3, in: animation) - midpoint(ofFrame: 1, in: animation))
        #expect(animation.frameIndex(at: playback.elapsedTime, animated: true) == 3)
        // One full cycle later the loop lands on the same frame.
        clock.advance(by: animation.duration)
        #expect(animation.frameIndex(at: playback.elapsedTime, animated: true) == 3)
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

    @Test func reduceMotionSelectsTheStaticFirstFrameAtAnyPlaybackTime() throws {
        let animation = try bundledAnimation()
        for elapsed in [0, animation.duration / 2, animation.duration * 40.25] {
            #expect(animation.frameIndex(at: elapsed, animated: false) == 0)
        }
    }

    @Test func reduceMotionAndInactiveScenesPausePlayback() {
        let animates = SplashArtView.shouldAnimate
        #expect(animates(.active, false, 2))
        #expect(!animates(.active, true, 2))
        #expect(!animates(.inactive, false, 2))
        #expect(!animates(.background, false, 2))
        #expect(!animates(.active, false, 1))
    }

    // MARK: - Frame lifetime

    @Test func framesAreDecodedOnceWhileAnyOwnerIsAliveAndReleasedAfterTheLast() throws {
        let url = try #require(SplashAnimation.bundledURL)
        let loads = Counter()
        let store = SplashAnimationStore {
            loads.count += 1
            return SplashAnimation(url: url)
        }
        #expect(!store.isRetainingFrames)

        var first = store.lease()
        var second = store.lease()
        #expect(first != nil)
        #expect(first === second)
        #expect(loads.count == 1)
        #expect(store.isRetainingFrames)

        first = nil
        #expect(store.isRetainingFrames)
        second = nil
        #expect(!store.isRetainingFrames)

        do {
            let third = store.lease()
            withExtendedLifetime(third) {
                #expect(loads.count == 2)
                #expect(store.isRetainingFrames)
            }
        }
        #expect(!store.isRetainingFrames)
    }

    @Test func sharedStoreServesTheBundledAnimation() throws {
        let lease = try #require(SplashAnimationStore.shared.lease())
        #expect(lease.animation.frameCount > 1)
        #expect(lease.animation.duration > 0)
    }

    /// Measures what a lease retains: the decoded backing store of every frame
    /// (`bytesPerRow * height`), which is the cost the lease bounds (ios#256).
    /// The value is printed into the test log alongside the encoded file size.
    @Test func decodedFrameFootprintIsMeasured() throws {
        let url = try #require(SplashAnimation.bundledURL)
        let animation = try #require(SplashAnimation(url: url))
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let encodedBytes = try #require(fileSize)
        let decodedBytes = animation.frames.reduce(0) { $0 + $1.bytesPerRow * $1.height }
        print(
            "SplashAnimation footprint: \(animation.frameCount) frames, "
                + "\(decodedBytes) decoded bytes retained per lease, "
                + "\(encodedBytes) encoded bytes on disk")
        #expect(decodedBytes > encodedBytes)
    }
}
