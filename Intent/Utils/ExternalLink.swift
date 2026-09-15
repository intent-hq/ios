import Foundation

/// The supported contract for backend-supplied external links — the strings
/// context-mention chips and PR-monitor chips hand to `openURL`. Only absolute
/// `http` / `https` URLs with a host are opened; `javascript:`, `file:`,
/// `tel:`, custom app schemes, scheme-less and malformed strings all resolve
/// to nil so a daemon-supplied string can never drive the system into a
/// non-web handler. There is deliberately no app-link (`intent://`) passthrough:
/// neither call site has a documented need for one.
nonisolated enum ExternalLink {
    /// Schemes an external link may carry (compared case-insensitively).
    static let allowedSchemes: Set<String> = ["http", "https"]

    /// The URL to hand to `openURL`, or nil when `string` is not an absolute
    /// http/https URL with a non-empty host.
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
