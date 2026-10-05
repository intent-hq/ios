import Foundation

struct MarkdownCodeFence {
    private static let openingRegex = #/^( {0,3})(`{3,}|~{3,})(.*)$/#
    private static let closingRegex = #/^ {0,3}(`{3,}|~{3,})[ \t]*$/#

    let marker: Substring
    let indent: Int
    let isMermaid: Bool

    init?(opening line: String) {
        guard let match = line.wholeMatch(of: Self.openingRegex) else { return nil }
        guard match.2.first != "`" || !match.3.contains("`") else { return nil }
        marker = match.2
        indent = match.1.count
        isMermaid = match.3.trimmingCharacters(in: .whitespaces) == "mermaid"
    }

    func closes(with line: String) -> Bool {
        guard let match = line.wholeMatch(of: Self.closingRegex) else { return false }
        return match.1.first == marker.first && match.1.count >= marker.count
    }

    func removingIndent(from line: String) -> String {
        let spaces = line.prefix { $0 == " " }.prefix(indent).count
        return String(line.dropFirst(spaces))
    }
}
