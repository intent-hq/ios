import Foundation

struct ContextMention: Equatable {
    let provider: String
    let identifier: String
    let title: String
    let url: String?

    enum Segment: Equatable {
        case text(String)
        case mention(ContextMention)
    }

    private static let tokenRegex = #/@context\[([^\]]+)\]/#
    private static let base64QuantumSize = 4

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

    static func replacingTokensWithTitles(in text: String) -> String {
        segments(from: text).map { segment in
            switch segment {
            case .text(let run): return run
            case .mention(let mention): return mention.title
            }
        }
        .joined()
    }

    static func mention(fromPayload payload: String) -> Self {
        if payload.hasPrefix("eyJ"), let mention = decodeBase64JSON(payload) {
            return mention
        }
        return decodePipeSeparated(payload)
    }

    private struct Payload: Decodable {
        let provider: String?
        let identifier: String?
        let title: String?
        let url: String?
    }

    private static func decodeBase64JSON(_ payload: String) -> Self? {
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
