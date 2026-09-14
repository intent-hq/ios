import Foundation

/// Monotonic playback position that excludes time spent paused.
struct SplashPlaybackState {
    private(set) var accumulatedTime: TimeInterval = 0
    private(set) var startedAt: TimeInterval?

    mutating func setRunning(_ shouldRun: Bool, at timestamp: TimeInterval) {
        if shouldRun {
            if startedAt == nil { startedAt = timestamp }
        } else if let startedAt {
            accumulatedTime += max(0, timestamp - startedAt)
            self.startedAt = nil
        }
    }

    func elapsedTime(at timestamp: TimeInterval) -> TimeInterval {
        guard let startedAt else { return accumulatedTime }
        return accumulatedTime + max(0, timestamp - startedAt)
    }
}
