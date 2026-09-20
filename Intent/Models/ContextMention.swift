import Foundation

/// A context mention decoded from an `@context[...]` token in user-message
/// text. Mirrors the FE's `parseInlineMentions` context branch
/// (cloudlands-fe `ChatMessage.svelte`): the payload is either base64-encoded
/// JSON (produced by the TipTap editor's `renderText`) or the legacy
/// pipe-separated `provider|identifier|title` form.
struct ContextMention: Equatable {
    let provider: String
    let identifier: String
    let title: String
    let url: String?

    /// A run of user-message text: either plain text or a context mention.
    enum Segment: Equatable {
        case text(String)
        case mention(ContextMention)
    }

    /// Matches `@context[...]` tokens; group 1 is the inner payload.
    /// Equivalent to the FE mention regex's `context\[[^\]]+\]` branch.
    private static let tokenRegex = #/@context\[([^\]]+)\]/#
    private static let base64QuantumSize = 4

    /// Splits `text` into interleaved plain-text and mention segments,
    /// preserving all surrounding text.
    static func segments(from text: String) -> [Segment] {
        var segments: [Segment] = []
        var lastIndex = text.startIndex

        for match in text.matches(of: tokenRegex) {
            let matchRange = match.range
            if matchRange.lowerBound > lastIndex {
                segments.append(.text(String(text[lastIndex..<matchRange.lowerBound])))
            }
            segments.append(.mention(mention(fromPayload: String(match.1))))
            lastIndex = matchRange.upperBound
        }

        if lastIndex < text.endIndex {
            segments.append(.text(String(text[lastIndex...])))
        }

        if segments.isEmpty, !text.isEmpty {
            segments.append(.text(text))
        }

        return segments
    }

    /// Replaces each `@context[...]` token in `text` with its decoded title,
    /// for plain-text surfaces like clipboard copy (mirrors the FE, which
    /// copies chip labels rather than raw tokens).
    static func replacingTokensWithTitles(in text: String) -> String {
        segments(from: text).map { segment in
            switch segment {
            case .text(let run): return run
            case .mention(let mention): return mention.title
            }
        }
        .joined()
    }

    /// Decodes one token payload (the text between the brackets). A payload
    /// starting with `eyJ` (base64 for `{"`) is treated as base64-encoded
    /// JSON; malformed base64/JSON falls back to pipe parsing.
    static func mention(fromPayload payload: String) -> Self {
        if payload.hasPrefix("eyJ"), let mention = decodeBase64JSON(payload) {
            return mention
        }
        return decodePipeSeparated(payload)
    }

    /// JSON shape written by the FE editor's ContextMention `renderText`
    /// (TipTapEditor.svelte); only the fields the chip renders are decoded.
    private struct Payload: Decodable {
        let provider: String?
        let identifier: String?
        let title: String?
        let url: String?
    }

    private static func decodeBase64JSON(_ payload: String) -> Self? {
        // JS `atob` tolerates missing padding; Data(base64Encoded:) does not.
        let padded = payload.padding(
            toLength: (payload.count + base64QuantumSize - 1) / base64QuantumSize * base64QuantumSize,
            withPad: "=",
            startingAt: 0
        )
        guard let data = Data(base64Encoded: padded),
              let json = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        let provider = json.provider.flatMap { $0.isEmpty ? nil : $0 } ?? "browser"
        let identifier = json.identifier ?? ""
        var title = json.title ?? ""
        if title.isEmpty { title = identifier }
        if title.isEmpty { title = "Shared context" }
        let url = json.url.flatMap { $0.isEmpty ? nil : $0 }
        return Self(provider: provider, identifier: identifier, title: title, url: url)
    }

    private static func decodePipeSeparated(_ payload: String) -> Self {
        let parts = payload.components(separatedBy: "|")
        let provider = !parts.isEmpty && !parts[0].isEmpty ? parts[0] : "browser"
        let identifier = parts.count > 1 ? parts[1] : ""
        var title = parts.count > 2 ? parts[2] : ""
        if title.isEmpty { title = identifier }
        return Self(provider: provider, identifier: identifier, title: title, url: nil)
    }
}
