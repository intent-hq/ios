import Foundation

/// Parsing and stripping of `<!-- suggested-prompts ... -->` blocks.
///
/// A block is well-formed only when the opener ends its own line, the closing
/// `-->` stands alone on a later line, and the opener is not inside a fenced
/// code region. Only the last well-formed block supplies prompts, and a block
/// whose body carries body-text-shaped lines (headings, fences, table rows,
/// Mermaid edges) is discarded entirely — response body text must never render
/// as chips, and stripping must never remove it.
enum SuggestedPrompts {
    /// Maximum number of chips a block can contribute.
    static let maxPrompts = 6
    /// Maximum length of a single prompt; longer lines are dropped.
    static let maxPromptLength = 200

    private static let openerPattern = "<!--[ \t]*suggested-prompts[ \t]*$"

    private struct Block {
        let openerLine: Int
        let closerLine: Int
        let openerPrefix: String
        let body: [String]
    }

    /// Prompts from the last well-formed block, capped and sanitized.
    static func parse(_ text: String) -> [String] {
        guard let last = blocks(in: text).last else { return [] }
        return prompts(from: last.body)
    }

    /// Removes every well-formed block, leaving all other text untouched.
    static func stripBlocks(from text: String) -> String {
        let found = blocks(in: text)
        guard !found.isEmpty else { return text }
        var lines = text.components(separatedBy: "\n")
        var dropped = Set<Int>()
        for block in found {
            for index in block.openerLine...block.closerLine { dropped.insert(index) }
            if !block.openerPrefix.isEmpty {
                lines[block.openerLine] = block.openerPrefix
                dropped.remove(block.openerLine)
            }
        }
        return lines.enumerated()
            .filter { !dropped.contains($0.offset) }
            .map(\.element)
            .joined(separator: "\n")
    }

    /// Well-formed blocks that also pass the body sanity gate, in order.
    private static func blocks(in text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var result: [Block] = []
        var inFence = false
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                index += 1
                continue
            }
            guard !inFence,
                  let openerRange = line.range(of: openerPattern, options: .regularExpression) else {
                index += 1
                continue
            }
            // The closing `-->` must stand alone on a later line; an embedded
            // `-->` (Mermaid edge, prose arrow) never closes a block.
            var closerLine: Int?
            var scan = index + 1
            while scan < lines.count {
                if lines[scan].trimmingCharacters(in: .whitespaces) == "-->" {
                    closerLine = scan
                    break
                }
                scan += 1
            }
            guard let closer = closerLine else {
                index += 1
                continue
            }
            let body = Array(lines[(index + 1)..<closer])
            if isPromptBody(body) {
                result.append(Block(
                    openerLine: index,
                    closerLine: closer,
                    openerPrefix: String(line[line.startIndex..<openerRange.lowerBound]),
                    body: body))
            }
            index = closer + 1
        }
        return result
    }

    private static func isPromptBody(_ body: [String]) -> Bool {
        let lines = body
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        return !lines.contains(where: looksLikeBodyText)
    }

    private static func looksLikeBodyText(_ line: String) -> Bool {
        if line.hasPrefix("#") || line.hasPrefix("```") || line.hasPrefix("~~~")
            || line.hasPrefix("|") || line.hasPrefix("<!--") {
            return true
        }
        // Mermaid edges and stray closers cannot be prompts.
        return line.contains("-->")
    }

    private static func prompts(from body: [String]) -> [String] {
        var result: [String] = []
        for raw in body {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.count > maxPromptLength { continue }
            result.append(line)
            if result.count == maxPrompts { break }
        }
        return result
    }
}
