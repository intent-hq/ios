import Foundation

struct MermaidMarkdownContent {
    struct PendingDiagram {
        let markdown: String
        let language: String
        var isVisual = false
    }

    let markdown: String
    let sources: [String: String]
    let visuals: [String: String]
    let pending: PendingDiagram?

    init(_ content: String) {
        var lines = content.components(separatedBy: "\n")
        var sources: [String: String] = [:]
        var visuals: [String: String] = [:]
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
            let isEmbedded = fence.isMermaid || fence.isInlineVisual
            let key = "\(prefix)\(sources.count + visuals.count)"
            if isEmbedded, end < lines.count {
                let body = lines[bodyStart..<end]
                    .map { fence.removingIndent(from: Self.normalized($0)) }
                    .joined(separator: "\n")
                if fence.isMermaid { sources[key] = body } else { visuals[key] = body }
                let carriageReturn = lines[index].hasSuffix("\r") ? "\r" : ""
                lines[index] = String(repeating: " ", count: fence.indent) + String(fence.marker) + key + carriageReturn
            } else if isEmbedded {
                let label = fence.isInlineVisual ? "Generating visual" : "Generating diagram"
                let placeholder = [String(fence.marker) + key, label, String(fence.marker)]
                pending = PendingDiagram(
                    markdown: (Array(lines[..<index]) + placeholder).joined(separator: "\n"),
                    language: key,
                    isVisual: fence.isInlineVisual
                )
            }
            index = min(end + 1, lines.count)
        }
        markdown = lines.joined(separator: "\n")
        self.sources = sources
        self.visuals = visuals
        self.pending = pending
    }

    private static func normalized(_ line: String) -> String {
        line.hasSuffix("\r") ? String(line.dropLast()) : line
    }
}
