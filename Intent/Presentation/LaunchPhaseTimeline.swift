import Foundation

enum LaunchPhaseTimeline {
    static func delay(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
        try Task.checkCancellation()
    }

    @discardableResult
    static func poll(
        until condition: () -> Bool,
        timeout: Duration,
        interval: Duration
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            if condition() { return true }
            let now = clock.now
            guard now < deadline else { return false }
            try await clock.sleep(for: min(interval, now.duration(to: deadline)))
        }
    }
}
