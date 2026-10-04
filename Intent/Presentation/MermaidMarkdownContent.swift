import Foundation

struct MermaidMarkdownContent {
    struct PendingDiagram {
        let markdown: String
        let language: String
    }

    let markdown: String
    let sources: [String: String]
    let pending: PendingDiagram?

    init(_ content: String) {
        var lines = content.components(separatedBy: "\n")
        var sources: [String: String] = [:]
        var pending: PendingDiagram?
        var prefix = "intent-mermaid-"
        while content.contains(prefix) { prefix += "-" }
        var index = 0
        while index < lines.count {
            guard let fence = MarkdownCodeFence(opening: Self.normalized(lines[index])) else {
                index += 1
                continue
            }
            let bodyStart = index + 1
            var end = bodyStart
            while end < lines.count, !fence.closes(with: Self.normalized(lines[end])) { end += 1 }
            if fence.isMermaid, end < lines.count {
                let key = "\(prefix)\(sources.count)"
                sources[key] = lines[bodyStart..<end]
                    .map { fence.removingIndent(from: Self.normalized($0)) }
                    .joined(separator: "\n")
                let carriageReturn = lines[index].hasSuffix("\r") ? "\r" : ""
                // Keep one Markdown document so reference links and lists retain their context.
                lines[index] = String(repeating: " ", count: fence.indent) + String(fence.marker) + key + carriageReturn
            } else if fence.isMermaid {
                let key = "\(prefix)\(sources.count)"
                // A nonempty code block keeps an opening-only fence visible in the Markdown parser.
                let placeholder = [String(fence.marker) + key, "Generating diagram", String(fence.marker)]
                pending = PendingDiagram(
                    markdown: (Array(lines[..<index]) + placeholder).joined(separator: "\n"),
                    language: key
                )
            }
            index = min(end + 1, lines.count)
        }
        markdown = lines.joined(separator: "\n")
        self.sources = sources
        self.pending = pending
    }

    private static func normalized(_ line: String) -> String {
        line.hasSuffix("\r") ? String(line.dropLast()) : line
    }
}
