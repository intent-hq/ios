import Foundation

/// Parsing and stripping of `<!-- suggested-prompts ... -->` blocks.
///
/// A block is well-formed only when the opener ends its own line, a later line
/// closes it — either a standalone `-->`, or a line ending in `-->` whose
/// non-empty remainder becomes the final body line — and the opener is not
/// inside a fenced code region. Every well-formed block is stripped from the rendered text, and
/// only the last one supplies prompts — it yields nothing when any captured line
/// is body-text-shaped (heading, fence, table row, Mermaid edge), so response
/// body text can never render as chips.
///
/// Mirrors `findSuggestedPromptsBlocks` / `parseSuggestedPrompts` in the desktop
/// app's `messageParser.ts`, except that prompt lines are kept verbatim (iOS has
/// no `Label|` / `delay:N|` stripping) and a body line starting with `<!--` also
/// disqualifies the block.
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
        let lines = last.body
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty, !lines.contains(where: looksLikeBodyText) else { return [] }
        return prompts(from: lines)
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

    /// Every well-formed block, in order, ungated.
    private static func blocks(in text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var result: [Block] = []
        var fence: (char: Character, length: Int)?
        var index = 0
        while index < lines.count {
            let line = trimmingTrailingWhitespace(lines[index])
            if let marker = fenceMarker(line) {
                if let open = fence {
                    // Only a matching, at-least-as-long, bare marker closes.
                    if marker.char == open.char, marker.length >= open.length,
                       marker.info.trimmingCharacters(in: .whitespaces).isEmpty {
                        fence = nil
                    }
                } else {
                    fence = (marker.char, marker.length)
                }
                index += 1
                continue
            }
            guard fence == nil,
                  let openerRange = line.range(of: openerPattern, options: .regularExpression) else {
                index += 1
                continue
            }
            // The closing `-->` either stands alone on a later line, or ends a
            // later line whose non-empty remainder becomes the final body line;
            // an embedded `-->` mid-line (Mermaid edge, prose arrow) never
            // closes a block. A second opener means this one was never closed.
            var closerLine: Int?
            var closerRemainder: String?
            var scan = index + 1
            while scan < lines.count {
                let candidate = trimmingTrailingWhitespace(lines[scan])
                if candidate.trimmingCharacters(in: .whitespaces) == "-->" {
                    closerLine = scan
                    break
                }
                if candidate.hasSuffix("-->") {
                    let remainder = trimmingTrailingWhitespace(String(candidate.dropLast(3)))
                    if !remainder.isEmpty {
                        closerLine = scan
                        closerRemainder = remainder
                        break
                    }
                }
                if candidate.range(of: openerPattern, options: .regularExpression) != nil { break }
                scan += 1
            }
            guard let closer = closerLine else {
                // Unclosed opener — resume from wherever the scan stopped so a
                // later well-formed block is still found.
                index = scan > index ? scan : index + 1
                continue
            }
            var body = Array(lines[(index + 1)..<closer])
            if let remainder = closerRemainder { body.append(remainder) }
            result.append(Block(
                openerLine: index,
                closerLine: closer,
                openerPrefix: String(line[line.startIndex..<openerRange.lowerBound]),
                body: body))
            index = closer + 1
        }
        return result
    }

    /// Opening/closing markdown fence (backtick or tilde), indented at most 3.
    private static func fenceMarker(_ line: String) -> (char: Character, length: Int, info: String)? {
        var index = line.startIndex
        var indent = 0
        while index < line.endIndex, line[index] == " " {
            indent += 1
            index = line.index(after: index)
        }
        guard indent <= 3, index < line.endIndex else { return nil }
        let char = line[index]
        guard char == "`" || char == "~" else { return nil }
        var length = 0
        while index < line.endIndex, line[index] == char {
            length += 1
            index = line.index(after: index)
        }
        guard length >= 3 else { return nil }
        return (char, length, String(line[index...]))
    }

    private static func trimmingTrailingWhitespace(_ line: String) -> String {
        var result = line
        while let last = result.last, last.isWhitespace || last.isNewline {
            result.removeLast()
        }
        return result
    }

    private static func looksLikeBodyText(_ line: String) -> Bool {
        if line.hasPrefix("|") || line.hasPrefix("<!--") { return true }
        if line.range(of: "^#{1,6}(\\s|$)", options: .regularExpression) != nil { return true }
        if line.range(of: "^(`{3,}|~{3,})", options: .regularExpression) != nil { return true }
        // Mermaid edges cannot be prompts.
        return line.range(of: "\\S[ \t]*--+>", options: .regularExpression) != nil
    }

    private static func prompts(from lines: [String]) -> [String] {
        var result: [String] = []
        for line in lines {
            if line.utf16.count > maxPromptLength { continue }
            result.append(line)
            if result.count == maxPrompts { break }
        }
        return result
    }
}
