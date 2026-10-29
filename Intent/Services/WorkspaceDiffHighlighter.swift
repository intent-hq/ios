import Foundation

/// Adapts each side's hunk-wide syntax ranges to diff rows without changing text.
nonisolated enum WorkspaceDiffHighlighter {
    typealias Lines = [Int: [WorkspaceSyntaxHighlighter.Token]]

    static func displayedText(_ content: String) -> String {
        content.hasSuffix("\n") ? String(content.dropLast()) : content
    }

    @concurrent
    static func highlight(_ hunk: WorkspaceDiffHunk, path: String) async throws -> Lines {
        try Task.checkCancellation()
        let firstLine = hunk.lines.first { $0.newNumber == 1 || $0.oldNumber == 1 }?.content
        guard WorkspaceSyntaxHighlighter.language(forPath: path, firstLine: firstLine) != nil else { return [:] }
        var byteCount = 0
        for (index, line) in hunk.lines.enumerated() {
            try Task.checkCancellation()
            byteCount += displayedText(line.content).utf8.count + (index == 0 ? 0 : 1)
            guard byteCount <= WorkspaceSyntaxHighlighter.maxBytes else { return [:] }
        }
        var result: Lines = [:]
        if hunk.lines.contains(where: { $0.type == .deletion }) {
            result = try await highlightSide(hunk, path: path, side: .deletion)
        }
        let newSide = try await highlightSide(hunk, path: path, side: .addition)
        result.merge(newSide) { _, new in new }
        return result
    }

    private static func highlightSide(_ hunk: WorkspaceDiffHunk, path: String, side: WorkspaceDiffLine.Kind) async throws -> Lines {
        var source = ""
        var ranges: [(index: Int, range: NSRange)] = []
        var offset = 0
        for (index, line) in hunk.lines.enumerated() where line.type == side || line.type == .context {
            try Task.checkCancellation()
            let text = displayedText(line.content)
            let separator = ranges.isEmpty ? "" : "\n"
            source += separator
            offset += separator.utf16.count
            ranges.append((index, NSRange(location: offset, length: text.utf16.count)))
            source += text
            offset += text.utf16.count
        }
        let tokens = try await WorkspaceSyntaxHighlighter.highlight(text: source, path: path)
        var result: Lines = [:]
        var firstToken = 0
        for (index, range) in ranges {
            try Task.checkCancellation()
            // Context participates in both parses but is displayed from the new side.
            if side == .deletion, hunk.lines[index].type == .context { continue }
            while firstToken < tokens.count, NSMaxRange(tokens[firstToken].range) <= range.location {
                firstToken += 1
            }
            for token in tokens[firstToken...] {
                if token.range.location >= NSMaxRange(range) { break }
                let overlap = NSIntersectionRange(token.range, range)
                if overlap.length > 0 {
                    result[index, default: []].append(.init(
                        range: NSRange(location: overlap.location - range.location, length: overlap.length),
                        scope: token.scope
                    ))
                }
            }
        }
        return result
    }
}
