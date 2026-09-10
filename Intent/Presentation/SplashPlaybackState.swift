import Foundation

/// Monotonic playback position that excludes time spent paused.
struct SplashPlaybackState {
    private(set) var accumulatedTime: TimeInterval = 0
    private(set) var startedAt: Date?

    mutating func setRunning(_ shouldRun: Bool, at date: Date) {
        if shouldRun {
            if startedAt == nil { startedAt = date }
        } else if let startedAt {
            accumulatedTime += max(0, date.timeIntervalSince(startedAt))
            self.startedAt = nil
        }
    }

    func elapsedTime(at date: Date) -> TimeInterval {
        guard let startedAt else { return accumulatedTime }
        return accumulatedTime + max(0, date.timeIntervalSince(startedAt))
    }
}