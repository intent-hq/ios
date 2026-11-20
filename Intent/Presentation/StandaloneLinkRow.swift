import Foundation

struct StandaloneLinkRow: Equatable {
    let title: String
    let url: URL

    private static let separator = "\u{1F}"
    private static let marker = "\(separator)intent-link-row\(separator)"

    init(title: String, url: URL) {
        self.title = title
        self.url = url
    }

    init?(paragraph: AttributedSubstring) {
        var url: URL?
        for run in paragraph.runs {
            let text = String(paragraph[run.range].characters)
            if run.imageURL != nil { return nil }
            if text.allSatisfy(\.isWhitespace) { continue }
            guard let link = run.link, url == nil || url == link else { return nil }
            url = link
        }
        let title = String(paragraph.characters)
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let url, !title.isEmpty else { return nil }
        self.init(title: title, url: url)
    }

    init?(languageHint: String?) {
        guard let languageHint, languageHint.hasPrefix(Self.marker) else { return nil }
        let payload = languageHint.dropFirst(Self.marker.count)
        guard let split = payload.range(of: Self.separator),
              let url = URL(string: String(payload[..<split.lowerBound])) else { return nil }
        let title = String(payload[split.upperBound...])
        guard !title.isEmpty else { return nil }
        self.init(title: title, url: url)
    }

    var languageHint: String {
        "\(Self.marker)\(url.absoluteString)\(Self.separator)\(title)"
    }

    var opensFile: Bool {
        guard let scheme = url.scheme?.lowercased() else { return true }
        return scheme == "intent" && url.host()?.lowercased() == "local" && url.path().hasPrefix("/file/")
    }

    static func rewriting(_ source: AttributedString) -> AttributedString {
        var result = source
        for (intent, range) in source.runs[\.presentationIntent] {
            guard let intent, let paragraph = intent.components.first,
                  paragraph.kind == .paragraph,
                  let row = Self(paragraph: source[range]) else { continue }
            var rebuilt: PresentationIntent?
            for component in intent.components.dropFirst().reversed() {
                rebuilt = PresentationIntent(component.kind, identity: component.identity, parent: rebuilt)
            }
            result[range].presentationIntent = PresentationIntent(
                .codeBlock(languageHint: row.languageHint),
                identity: paragraph.identity,
                parent: rebuilt
            )
        }
        return result
    }
}
