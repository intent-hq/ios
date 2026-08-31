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
/// Mirrors `scanSuggestedPrompts` / `parseSuggestedPrompts` in the desktop
/// app's `messageParser.ts`, including `Label|` / `delay:N|` stripping, the
/// four-chip cap, and dropping individually invalid lines.
enum SuggestedPrompts {
    /// Maximum number of chips a block can contribute (matches the desktop
    /// cap and the harness's "write 2–4 prompts" instruction).
    static let maxPrompts = 4
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
        prompts(fromLastOf: blocks(in: text))
    }

    /// Message-level scan mirroring the desktop's
    /// `parseSuggestedPromptsFromContentBlocks` (messageParser.ts): the
    /// combined text of every `.text` block — joined with the empty
    /// separator, exactly like the desktop — is scanned once, and each
    /// well-formed block's range is mapped back into its source blocks, so
    /// markup that is well-formed only across text-block boundaries still
    /// strips. Prompts and stripping come from this single scan, so they can
    /// never disagree (intent-hq/intent#3936: chips rendered while the raw
    /// markup leaked). Non-text blocks pass through untouched.
    static func parse(
        contentBlocks: [ContentBlock]
    ) -> (prompts: [String], contentBlocks: [ContentBlock]) {
        let combined = contentBlocks
            .filter { $0.type == .text }
            .map { $0.resolvedText ?? "" }
            .joined()
        let found = blocks(in: combined)
        let prompts = Self.prompts(fromLastOf: found)
        guard !found.isEmpty else { return (prompts, contentBlocks) }
        let ranges = utf16Ranges(of: found, in: combined)
        var textOffset = 0
        let cleaned = contentBlocks.map { block -> ContentBlock in
            guard block.type == .text else { return block }
            let units = Array((block.resolvedText ?? "").utf16)
            let blockStart = textOffset
            let blockEnd = blockStart + units.count
            textOffset = blockEnd
            var kept: [UTF16.CodeUnit] = []
            var cursor = 0
            for range in ranges {
                if range.end <= blockStart || range.start >= blockEnd { continue }
                let localStart = min(max(0, range.start - blockStart), units.count)
                let localEnd = min(max(0, range.end - blockStart), units.count)
                if localStart > cursor { kept.append(contentsOf: units[cursor..<localStart]) }
                cursor = max(cursor, localEnd)
            }
            kept.append(contentsOf: units[cursor...])
            guard kept.count != units.count else { return block }
            var next = block
            next.text = String(decoding: kept, as: UTF16.self)
            return next
        }
        return (prompts, cleaned)
    }

    /// Prompts from the last well-formed block: nothing when the body is
    /// empty or any captured line is body-text-shaped, otherwise the valid
    /// lines capped at `maxPrompts`.
    private static func prompts(fromLastOf found: [Block]) -> [String] {
        guard let last = found.last else { return [] }
        let lines = last.body
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty, !lines.contains(where: looksLikeBodyText) else { return [] }
        return prompts(from: lines)
    }

    /// UTF-16 offset range of each well-formed block within `text`: from the
    /// opener (any prefix before it survives) through the closer line's
    /// trailing newline (clamped at text end). Consuming that newline keeps
    /// the result identical to the line-based `stripBlocks(from:)` — which
    /// drops whole lines, separator included — so the message-level pass
    /// never turns a Markdown line break into a paragraph break.
    /// UTF-16 units (not Characters) keep offsets additive across block
    /// boundaries — grapheme clusters can merge when block texts concatenate.
    private static func utf16Ranges(of found: [Block], in text: String) -> [(start: Int, end: Int)] {
        let lines = text.components(separatedBy: "\n")
        var offsets: [Int] = []
        offsets.reserveCapacity(lines.count)
        var offset = 0
        for line in lines {
            offsets.append(offset)
            offset += line.utf16.count + 1
        }
        let length = text.utf16.count
        return found.map { block in
            (start: offsets[block.openerLine] + block.openerPrefix.utf16.count,
             end: min(offsets[block.closerLine] + lines[block.closerLine].utf16.count + 1, length))
        }
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
                    // An opener-shaped remainder (`<!-- suggested-prompts -->`)
                    // must not close the block: stripping is ungated, so it
                    // would delete the body text under an unclosed opener.
                    if !remainder.isEmpty,
                       remainder.range(of: openerPattern, options: .regularExpression) == nil {
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

    nonisolated private static func looksLikeBodyText(_ line: String) -> Bool {
        if line.hasPrefix("|") || line.hasPrefix("<!--") { return true }
        if line.range(of: "^#{1,6}(\\s|$)", options: .regularExpression) != nil { return true }
        if line.range(of: "^(`{3,}|~{3,})", options: .regularExpression) != nil { return true }
        // Mermaid edges cannot be prompts.
        return line.range(of: "\\S[ \t]*--+>", options: .regularExpression) != nil
    }

    private static func prompts(from lines: [String]) -> [String] {
        var result: [String] = []
        for line in lines {
            guard let prompt = parsePromptLine(line) else { continue }
            result.append(prompt)
            if result.count == maxPrompts { break }
        }
        return result
    }

    /// Strips `Label|` and `delay:N|` prefixes, mirroring the desktop's
    /// `parseSuggestedPromptLine`; empty or over-long results are dropped.
    /// `[0-9]` (not `\d`) keeps digit matching ASCII-only like the desktop's
    /// non-Unicode JS regex; ICU `\d` would also match e.g. Arabic-Indic digits.
    private static func parsePromptLine(_ line: String) -> String? {
        let delayPattern = "^delay:[0-9]+\\|"
        if let delayRange = line.range(
            of: delayPattern, options: [.regularExpression, .caseInsensitive]
        ) {
            let text = String(line[delayRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty || text.utf16.count > maxPromptLength ? nil : text
        }
        var promptPart = line
        if let pipeIndex = line.firstIndex(of: "|") {
            promptPart = String(line[line.index(after: pipeIndex)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let delayRange = promptPart.range(
            of: delayPattern, options: [.regularExpression, .caseInsensitive]
        ) {
            promptPart = String(promptPart[delayRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return promptPart.isEmpty || promptPart.utf16.count > maxPromptLength ? nil : promptPart
    }
}
