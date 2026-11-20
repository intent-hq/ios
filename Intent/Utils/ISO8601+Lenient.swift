import Foundation

extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let withoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func lenientDate(from raw: String?) -> Date? {
        guard let raw else { return nil }
        if let date = withFractionalSeconds.date(from: raw) { return date }
        return withoutFractionalSeconds.date(from: raw)
    }
}
