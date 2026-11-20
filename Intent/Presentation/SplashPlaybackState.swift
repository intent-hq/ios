import Foundation
import QuartzCore

protocol SplashPlaybackClock: AnyObject {
    var now: TimeInterval { get }
}

final class MediaTimeSplashClock: SplashPlaybackClock {
    var now: TimeInterval { CACurrentMediaTime() }
}

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
