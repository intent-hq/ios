import Foundation

struct MermaidMarkdownContent {
    let markdown: String
    let sources: [String: String]

    init(_ content: String) {
        var lines = content.components(separatedBy: "\n")
        var sources: [String: String] = [:]
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
            }
            index = min(end + 1, lines.count)
        }
        markdown = lines.joined(separator: "\n")
        self.sources = sources
    }

    private static func normalized(_ line: String) -> String {
        line.hasSuffix("\r") ? String(line.dropLast()) : line
    }
}
