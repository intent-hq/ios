import Foundation

nonisolated enum ExternalLink {
    static let allowedSchemes: Set<String> = ["http", "https"]

    static func url(from string: String?) -> URL? {
        guard let string else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme),
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }
}
