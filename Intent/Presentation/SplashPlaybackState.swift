import Foundation
import QuartzCore

/// Monotonic time source for splash playback (ios#247). Injectable so tests
/// step time deterministically; production samples `CACurrentMediaTime`,
/// which wall-clock (NTP) adjustments never move.
protocol SplashPlaybackClock: AnyObject {
    var now: TimeInterval { get }
}

final class MediaTimeSplashClock: SplashPlaybackClock {
    var now: TimeInterval { CACurrentMediaTime() }
}

/// Playback position on one monotonic clock that excludes time spent paused.
struct SplashPlaybackState {
    private let clock: any SplashPlaybackClock
    private(set) var accumulatedTime: TimeInterval = 0
    private(set) var startedAt: TimeInterval?

    init(clock: any SplashPlaybackClock = MediaTimeSplashClock()) {
        self.clock = clock
    }

    var isRunning: Bool { startedAt != nil }

    var elapsedTime: TimeInterval {
        guard let startedAt else { return accumulatedTime }
        return accumulatedTime + max(0, clock.now - startedAt)
    }

    mutating func setRunning(_ shouldRun: Bool) {
        if shouldRun {
            if startedAt == nil { startedAt = clock.now }
        } else if let startedAt {
            accumulatedTime += max(0, clock.now - startedAt)
            self.startedAt = nil
        }
    }
}