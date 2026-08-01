import Foundation

/// Shared lenient ISO8601/RFC-3339 timestamp parsing, used wherever the
/// daemon may emit a timestamp with or without fractional seconds (e.g.
/// `attentionRequestTimestamp`, agent `createdAt`/`updatedAt`/`lastActivity`).
extension ISO8601DateFormatter {
    /// Formatter for timestamps with fractional seconds, e.g.
    /// "2026-07-30T10:00:00.500Z". Cached since `ISO8601DateFormatter`
    /// construction is non-trivial and these are reused on every parse.
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Formatter for whole-second timestamps, e.g. "2026-07-30T10:00:00Z".
    static let withoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Parses `raw` trying the fractional-seconds formatter first, then
    /// falling back to whole seconds; nil when `raw` is nil or unparseable
    /// by either.
    static func lenientDate(from raw: String?) -> Date? {
        guard let raw else { return nil }
        if let date = withFractionalSeconds.date(from: raw) { return date }
        return withoutFractionalSeconds.date(from: raw)
    }
}
