import Foundation

/// Compact duration rendering for the chip detail headers — the iOS
/// counterpart of cloudlands-fe's `formatCompactDuration` (en): at most two
/// adjacent units (d/h/m/s), a zero adjacent unit omitted (so a smaller
/// remainder is truncated with it), rounded to the nearest second, negatives
/// clamped to "0s".
enum DurationFormat {
    static func compact(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return seconds > 0 ? "\(minutes)m \(seconds)s" : "\(minutes)m" }
        return "\(seconds)s"
    }
}
