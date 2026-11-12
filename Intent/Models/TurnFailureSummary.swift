import Foundation

/// The broad cause of a `turn-failure` attention notice, inferred
/// client-side from the notice's reason text. Mirrors the markers intentd
/// uses in `crates/intent-acp/src/error.rs`.
nonisolated enum TurnFailureCategory: Equatable, Sendable {
    /// The provider needs the user to sign in again.
    case authentication
    /// Anything else.
    case generic
    /// A transient connection problem (reset, refused, timed out).
    case network
    /// The provider's usage, rate, or billing limit was hit.
    case usageLimit

    /// The short card title for this category.
    var title: String {
        switch self {
        case .usageLimit: "Usage limit reached"
        case .authentication: "Sign-in required"
        case .network: "Connection lost"
        case .generic: "Turn failed"
        }
    }

    /// Used when the reason carries a category signal but no human sentence.
    var fallbackMessage: String? {
        switch self {
        case .usageLimit: "The provider's usage limit was reached."
        case .authentication: "The provider needs you to sign in again."
        case .network: "The connection to the provider was interrupted."
        case .generic: nil
        }
    }
}

/// A friendly presentation of a raw `turn-failure` reason.
///
/// Build one with `TurnFailureSummary(reason:)` (or
/// `AttentionNotice.turnFailureSummary`). Pure and total: any input,
/// including empty or malformed text, yields a summary, and the original
/// text is always kept verbatim in `rawDetails`.
///
/// - `title`: short headline for the category ("Usage limit reached").
/// - `message`: a human sentence with wrapper prefixes, RPC codes, and JSON
///   stripped; nil when the reason has no human text.
/// - `retryHint`: the provider's own reset wording ("try again at Nov 14th,
///   2026 8:07 AM", "resets 3pm"), when present.
/// - `linkURL`: the first http(s) link in the human text, when present.
nonisolated struct TurnFailureSummary: Equatable, Sendable {
    let category: TurnFailureCategory
    let message: String?
    let retryHint: String?
    let linkURL: URL?
    /// The untouched original reason, for a "Details" disclosure and Copy.
    let rawDetails: String

    var title: String { category.title }

    init(reason: String) {
        rawDetails = reason
        let peeled = Self.peelWrappers(reason)
        let embedded = EmbeddedError(peeledText: peeled)
        let human = embedded.humanText(peeledText: peeled)
        category = Self.classify(reason: reason, hints: embedded.hints)
        message = human ?? category.fallbackMessage
        retryHint = human.flatMap(Self.retryHint(in:))
        linkURL = human.flatMap(Self.firstLink(in:))
    }
}

extension AttentionNotice {
    /// The friendly summary for a `turn-failure` notice; nil for other kinds.
    nonisolated var turnFailureSummary: TurnFailureSummary? {
        kind == .turnFailure ? TurnFailureSummary(reason: reason) : nil
    }
}

// MARK: - Parsing

nonisolated private extension TurnFailureSummary {
    /// Repeatedly strips `internal error:`, `session/prompt failed:`, and
    /// `JSON-RPC error -NNNNN:` style prefixes (case-insensitive).
    static func peelWrappers(_ reason: String) -> String {
        var text = Substring(reason.trimmingCharacters(in: .whitespacesAndNewlines))
        let prefix = #/^\s*(?:internal error|session/prompt failed|json-rpc error\s*-?\d+)\s*:\s*/#.ignoresCase()
        while let match = text.prefixMatch(of: prefix), !match.output.isEmpty {
            text = text[match.range.upperBound...]
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func classify(reason: String, hints: [String]) -> TurnFailureCategory {
        let hints = hints.map { $0.lowercased() }
        if hints.contains(where: { ["usagelimitexceeded", "ratelimitexceeded", "rate_limit", "billing_error"].contains($0) }) {
            return .usageLimit
        }
        if hints.contains("authentication_failed") { return .authentication }

        let text = reason.lowercased()
        let usageMarkers = [
            "usage limit", "hit your limit", "rate limit", "rate_limit", "billing_error",
            "usagelimitexceeded", "ratelimitexceeded", "limit reached", "quota exceeded"
        ]
        if usageMarkers.contains(where: text.contains) { return .usageLimit }
        let authMarkers = [
            "authentication_failed", "authentication failed", "authentication required",
            "not authenticated", "unauthorized", "invalid api key", "please log in", "please sign in"
        ]
        if authMarkers.contains(where: text.contains) { return .authentication }
        let networkMarkers = [
            "econnreset", "connection reset", "econnrefused", "connection refused", "etimedout",
            "timed out", "timeout", "socket hang up", "network error", "connection closed"
        ]
        if networkMarkers.contains(where: text.contains) { return .network }
        return .generic
    }

    /// The provider's reset phrase, e.g. "try again at Nov 14th, 2026 8:07 AM"
    /// or "resets 3pm". Ends at a sentence period, `·`, newline, or the end.
    static func retryHint(in text: String) -> String? {
        let pattern = #/\b(?:try again (?:at|in|after|on)|resets(?: at| in| on)?|reset (?:at|in|on))\s+[^\n·]+?(?=\.\s|\.$|·|\n|$)/#
            .ignoresCase()
        guard let match = text.firstMatch(of: pattern) else { return nil }
        let hint = String(match.output).trimmingCharacters(in: .whitespaces)
        return hint.isEmpty ? nil : hint
    }

    static func firstLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range)
            .compactMap(\.url)
            .first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }
}

/// The JSON object (if any) embedded in a peeled reason, plus the text
/// before it.
nonisolated private struct EmbeddedError {
    /// Text before the first `{`, or the whole text when there is none.
    let leadingText: String
    /// The `message` field, from parsed JSON or (for malformed JSON) a
    /// best-effort scan of a `"message":"…"` pair.
    let message: String?
    /// `codexErrorInfo` / `errorKind` values (and `codexErrorInfo` object keys).
    let hints: [String]
    /// Whether the text contains a `{` at all.
    let hasObject: Bool

    init(peeledText text: String) {
        guard let open = text.firstIndex(of: "{") else {
            leadingText = text
            message = nil
            hints = []
            hasObject = false
            return
        }
        hasObject = true
        leadingText = String(text[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = text.lastIndex(of: "}").flatMap { $0 > open ? String(text[open...$0]) : nil }
        if let candidate,
           let data = candidate.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            message = Self.firstString(forKey: "message", in: object)
            hints = Self.hints(in: object)
        } else {
            message = Self.scanString(forKey: "message", in: text)
            hints = ["codexErrorInfo", "errorKind"].compactMap { Self.scanString(forKey: $0, in: text) }
        }
    }

    /// The best human sentence: the JSON message, else the leading text,
    /// else (no JSON at all) the peeled text itself.
    func humanText(peeledText: String) -> String? {
        let candidates = hasObject ? [message, leadingText] : [peeledText]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// Breadth-first search so a top-level `message` beats a nested one.
    private static func firstString(forKey key: String, in object: [String: Any]) -> String? {
        var queue: [[String: Any]] = [object]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            if let value = current[key] as? String { return value }
            queue.append(contentsOf: current.values.compactMap { $0 as? [String: Any] })
        }
        return nil
    }

    private static func hints(in object: [String: Any]) -> [String] {
        var result: [String] = []
        var queue: [[String: Any]] = [object]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            for key in ["codexErrorInfo", "errorKind"] {
                if let value = current[key] as? String { result.append(value) }
                if let value = current[key] as? [String: Any] { result.append(contentsOf: value.keys.sorted()) }
            }
            queue.append(contentsOf: current.values.compactMap { $0 as? [String: Any] })
        }
        return result
    }

    /// Extracts `"key":"value"` from text that is not valid JSON, decoding
    /// JSON string escapes when possible.
    private static func scanString(forKey key: String, in text: String) -> String? {
        let pattern = #/"(?<key>[A-Za-z]+)"\s*:\s*"(?<value>(?:\\.|[^"\\])*)"/#
        guard let match = text.matches(of: pattern).first(where: { $0.output.key == key }) else { return nil }
        let quoted = "\"\(match.output.value)\""
        if let data = quoted.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        return String(match.output.value)
    }
}
