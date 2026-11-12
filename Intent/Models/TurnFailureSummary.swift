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

    /// Used when a valid JSON reason carries a category signal but no
    /// human string field.
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
///   stripped. Nil only when the peeled reason is empty; otherwise falls
///   back to a JSON string field, the category sentence, or the peeled text.
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
        category = Self.classify(reason: reason, hints: embedded.hints)
        let human = embedded.humanText(peeledText: peeled, fallback: category.fallbackMessage)
        message = human
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

    /// Structured hints win; otherwise only the phrasings intentd matches
    /// (`crates/intent-acp/src/error.rs`) count, so generic "limit reached",
    /// "quota", or tool "timeout" text stays `.generic`.
    static func classify(reason: String, hints: [String]) -> TurnFailureCategory {
        let hints = hints.map { $0.lowercased() }
        if hints.contains(where: { ["usagelimitexceeded", "ratelimitexceeded", "rate_limit", "billing_error"].contains($0) }) {
            return .usageLimit
        }
        if hints.contains("authentication_failed") { return .authentication }

        let text = reason.lowercased()
        let usage = #/usage limit|usagelimitexceeded|ratelimitexceeded|hit your (?:session |weekly )?limit|\b5-hour limit|\bweekly limit|·\s*resets\b/#
        if text.contains(usage) { return .usageLimit }
        let authMarkers = [
            "authentication_failed", "authentication failed", "authentication required",
            "not authenticated", "unauthorized", "invalid api key", "please log in", "please sign in"
        ]
        if authMarkers.contains(where: text.contains) { return .authentication }
        let networkMarkers = [
            "econnreset", "connection reset", "econnrefused", "connection refused", "etimedout",
            "connection timed out", "timed out connecting", "network timeout", "socket hang up",
            "network error", "network is unreachable", "connection closed", "connection lost"
        ]
        if networkMarkers.contains(where: text.contains) { return .network }
        return .generic
    }

    /// The provider's reset phrase, e.g. "try again at Nov 14th, 2026 8:07 AM"
    /// or "resets 3pm". Ends at a sentence-ending period, `·`, newline, or
    /// the end; `a.m.`/`p.m.` do not end it. A "try again …" phrase counts
    /// only when it names a time or date ("in a moment" does not).
    static func retryHint(in text: String) -> String? {
        let pattern = #/\b(?<lead>try again (?:at|in|after|on|by)|resets(?: at| in| on)?|reset (?:at|in|on))\s+(?:[ap]\.m\.|[^\n·])+?(?=\.\s+[A-Z(]|\.\s*$|·|\n|$)/#
            .ignoresCase()
        let timeToken = #/\d|\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|mon|tue|wed|thu|fri|sat|sun)[a-z]*\b|tomorrow|tonight|noon|midnight|minute|hour|second|\bday|week|month/#
            .ignoresCase()
        for match in text.matches(of: pattern) {
            let hint = String(match.output.0).trimmingCharacters(in: .whitespaces)
            let isReset = match.output.lead.lowercased().hasPrefix("reset")
            let body = hint.dropFirst(match.output.lead.count)
            if isReset || body.contains(timeToken) { return hint }
        }
        return nil
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

/// What a peeled reason carries besides plain text.
nonisolated private enum EmbeddedError {
    /// A valid JSON object starts at the first `{`. `text` is its best human
    /// string field; `leading` is the text before the object.
    case object(leading: String, text: String?, hints: [String])
    /// No `{` in the text.
    case plain
    /// A `{` that is not valid JSON (truncated JSON or prose like
    /// "Invalid value {foo}"). `message` is a best-effort `"message":"…"` scan.
    case unparsed(message: String?, hints: [String])

    init(peeledText text: String) {
        guard let open = text.firstIndex(of: "{") else {
            self = .plain
            return
        }
        let candidate = text.lastIndex(of: "}").flatMap { $0 > open ? String(text[open...$0]) : nil }
        if let candidate,
           let data = candidate.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let leading = String(text[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
            self = .object(leading: leading, text: Self.humanField(in: object), hints: Self.hints(in: object))
        } else {
            let hints = ["codexErrorInfo", "errorKind"].compactMap { Self.scanString(forKey: $0, in: text) }
            self = .unparsed(message: Self.scanString(forKey: "message", in: text), hints: hints)
        }
    }

    var hints: [String] {
        switch self {
        case .plain: []
        case let .object(_, _, hints), let .unparsed(_, hints): hints
        }
    }

    /// The best human sentence; nil only when every candidate is empty.
    func humanText(peeledText: String, fallback: String?) -> String? {
        let candidates: [String?] = switch self {
        case .plain: [peeledText]
        case let .object(leading, text, _): [text, leading, fallback, peeledText]
        case let .unparsed(message, _): [message, peeledText]
        }
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// `message`, `details`, `detail`, `reason`, or a string `error` (each
    /// searched breadth-first, so top-level wins), then `error.type`, then a
    /// top-level `type` other than the envelope value "error".
    private static func humanField(in object: [String: Any]) -> String? {
        for key in ["message", "details", "detail", "reason", "error"] {
            if let value = firstString(forKey: key, in: object) { return value }
        }
        let errorType = (object["error"] as? [String: Any])?["type"] as? String
        let type = (object["type"] as? String).flatMap { $0 == "error" ? nil : $0 }
        return [errorType, type].compactMap { $0 }.first { !$0.isEmpty }
    }

    private static func firstString(forKey key: String, in object: [String: Any]) -> String? {
        var queue: [[String: Any]] = [object]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            if let value = current[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
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
