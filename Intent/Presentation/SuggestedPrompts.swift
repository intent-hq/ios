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
/// Empty repeated opener lines immediately before a closed block are treated
/// as part of that block. Unclosed openers with intervening body text survive.
///
/// Base syntax mirrors `scanSuggestedPrompts` / `parseSuggestedPrompts` in the
/// desktop app's `messageParser.ts`, including `Label|` / `delay:N|` stripping,
/// the four-chip cap, and dropping individually invalid lines. The
/// HTML-escaped spelling (`&lt;!-- suggested-prompts` ... `--&gt;`), which a
/// model can copy from an XML-escaped history replay, is a block too: it
/// closes only on the escaped closer and its lines are entity-decoded once.
/// Shared cases: `IntentTests/Fixtures/suggested-prompts/` (monorepo
/// `docs/protocol/suggested-prompts.md`). Empty duplicate
/// opener recovery also removes the otherwise visible leftover marker on iOS.
enum SuggestedPrompts {
    private static let markdownMarkerLength = 3
    private static let maximumFenceIndent = 3

    /// Maximum number of chips a block can contribute (matches the desktop
    /// cap and the harness's "write 2–4 prompts" instruction).
    static let maxPrompts = 4
    /// Maximum length of a single prompt; longer lines are dropped.
    static let maxPromptLength = 200

    private static let openerPattern = "(<|&lt;)!--[ \t]*suggested-prompts[ \t]*$"
    private static let escapedOpenerPrefix = "&lt;"
    private static let closer = "-->"
    private static let escapedCloser = "--&gt;"

    private struct Block {
        let openerLine: Int
        let closerLine: Int
        let openerPrefix: String
        let body: [String]
        /// Opened with `&lt;!--`: closes on `--&gt;`, lines are entity-decoded.
        let escaped: Bool
    }

    private struct CloserSearch {
        let closerLine: Int?
        let closerRemainder: String?
    }

    private struct FenceMarker {
        let character: Character
        let length: Int
        let info: String
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
            .map { (last.escaped ? decodeEntities($0) : $0).trimmingCharacters(in: .whitespacesAndNewlines) }
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
            (
                start: offsets[block.openerLine] + block.openerPrefix.utf16.count,
                end: min(offsets[block.closerLine] + lines[block.closerLine].utf16.count + 1, length)
            )
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
                fence = nextFence(after: marker, in: fence)
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
            let escaped = line[openerRange].hasPrefix(escapedOpenerPrefix)
            let closerSearch = findCloser(
                in: lines,
                after: index,
                closer: escaped ? escapedCloser : closer
            )
            guard let closer = closerSearch.closerLine else {
                // Unclosed opener: rescan from the next line so the fence
                // bookkeeping above sees every line and a later well-formed
                // block is still found.
                index += 1
                continue
            }
            var body = Array(lines[(index + 1)..<closer])
            if let remainder = closerSearch.closerRemainder { body.append(remainder) }
            let prefix = String(line[line.startIndex..<openerRange.lowerBound])
            let start = redundantOpenerStart(in: lines, before: index, prefix: prefix)
            result.append(Block(
                openerLine: start,
                closerLine: closer,
                openerPrefix: start == index ? prefix : "",
                body: body,
                escaped: escaped
            ))
            index = closer + 1
        }
        return result
    }

    private static func findCloser(
        in lines: [String],
        after openerIndex: Int,
        closer: String
    ) -> CloserSearch {
        var closerLine: Int?
        var closerRemainder: String?
        var fence: (char: Character, length: Int)?
        var scan = openerIndex + 1
        while scan < lines.count {
            let candidate = trimmingTrailingWhitespace(lines[scan])
            // A closer or opener inside a fenced region never counts, so a
            // fenced example cannot close the block and strip reply text.
            if let marker = fenceMarker(candidate) {
                fence = nextFence(after: marker, in: fence)
                scan += 1
                continue
            }
            if fence != nil {
                scan += 1
                continue
            }
            if candidate.trimmingCharacters(in: .whitespaces) == closer {
                closerLine = scan
                break
            }
            if candidate.hasSuffix(closer) {
                let remainder = trimmingTrailingWhitespace(
                    String(candidate.dropLast(closer.count))
                )
                // An opener-shaped remainder must not close the block: stripping
                // is ungated and would delete text under an unclosed opener.
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
        return CloserSearch(closerLine: closerLine, closerRemainder: closerRemainder)
    }

    /// Fence state after a marker line: only a matching, at-least-as-long,
    /// bare marker closes an open fence; any marker opens one otherwise.
    private static func nextFence(
        after marker: FenceMarker,
        in fence: (char: Character, length: Int)?
    ) -> (char: Character, length: Int)? {
        guard let open = fence else { return (marker.character, marker.length) }
        let closes = marker.character == open.char && marker.length >= open.length
            && marker.info.trimmingCharacters(in: .whitespaces).isEmpty
        return closes ? nil : open
    }

    /// Opening/closing markdown fence (backtick or tilde), indented at most 3.
    private static func fenceMarker(_ line: String) -> FenceMarker? {
        var index = line.startIndex
        var indent = 0
        while index < line.endIndex, line[index] == " " {
            indent += 1
            index = line.index(after: index)
        }
        guard indent <= Self.maximumFenceIndent, index < line.endIndex else { return nil }
        let char = line[index]
        guard char == "`" || char == "~" else { return nil }
        var length = 0
        while index < line.endIndex, line[index] == char {
            length += 1
            index = line.index(after: index)
        }
        guard length >= Self.markdownMarkerLength else { return nil }
        return FenceMarker(character: char, length: length, info: String(line[index...]))
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
            of: delayPattern,
            options: [.regularExpression, .caseInsensitive]
        ) {
            let text = String(line[delayRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return isValidPrompt(text) ? text : nil
        }
        var promptPart = line
        if let afterLabel = SuggestedPromptLinks.textAfterLabel(line) {
            promptPart = afterLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let delayRange = promptPart.range(
            of: delayPattern,
            options: [.regularExpression, .caseInsensitive]
        ) {
            promptPart = String(promptPart[delayRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return isValidPrompt(promptPart) ? promptPart : nil
    }

    /// Non-empty, and the visible text (link labels in place of their
    /// markdown) fits `maxPromptLength`, like the desktop.
    private static func isValidPrompt(_ text: String) -> Bool {
        !text.isEmpty && SuggestedPromptLinks.visibleText(text).utf16.count <= maxPromptLength
    }
}

private extension SuggestedPrompts {
    /// Decodes the entities a model imitating escaped text emits, in one pass
    /// (so `&amp;lt;` becomes `&lt;`): the five XML named entities plus decimal
    /// (1–7 digits) and hex (1–6 digits) references. Unknown, zero,
    /// out-of-range and surrogate references stay literal, matching the
    /// desktop's `decodeEscapedPromptText`.
    static let maxEntityBodyLength = 8
    static let hexRadix = 16
    static let decimalRadix = 10
    static let maxHexDigits = 6
    static let maxDecimalDigits = 7

    static func decodeEntities(_ line: String) -> String {
        let named: [String: String] = ["lt": "<", "gt": ">", "quot": "\"", "apos": "'", "amp": "&"]
        let scalars = Array(line.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "&", let semicolon = scalars[(index + 1)...].firstIndex(of: ";"),
                  semicolon - index - 1 <= maxEntityBodyLength else {
                out.append(scalars[index])
                index += 1
                continue
            }
            let name = String(String.UnicodeScalarView(scalars[(index + 1)..<semicolon]))
            if let decoded = named[name] ?? numericReference(name) {
                out.append(contentsOf: decoded.unicodeScalars)
                index = semicolon + 1
            } else {
                out.append(scalars[index])
                index += 1
            }
        }
        return String(out)
    }

    /// `#123` / `#x1F` body of a numeric reference, decoded to its scalar.
    private static func numericReference(_ body: String) -> String? {
        guard body.hasPrefix("#") else { return nil }
        var digits = body.dropFirst()
        let radix: Int
        let maxDigits: Int
        if let first = digits.first, first == "x" || first == "X" {
            digits = digits.dropFirst()
            radix = hexRadix
            maxDigits = maxHexDigits
        } else {
            radix = decimalRadix
            maxDigits = maxDecimalDigits
        }
        let allowed = radix == hexRadix ? "0123456789abcdefABCDEF" : "0123456789"
        guard !digits.isEmpty, digits.count <= maxDigits, digits.allSatisfy(allowed.contains),
              let value = UInt32(digits, radix: radix), value > 0,
              let scalar = Unicode.Scalar(value) else { return nil }
        return String(Character(scalar))
    }

    /// Only absorb standalone openers separated by whitespace, and only after
    /// a closed block has been found. Stop at any prose or fence so an earlier
    /// unclosed example cannot consume response text (ios#445).
    static func redundantOpenerStart(in lines: [String], before index: Int, prefix: String) -> Int {
        guard prefix.trimmingCharacters(in: .whitespaces).isEmpty else { return index }
        var start = index
        var previous = index
        while previous > 0 {
            previous -= 1
            let candidate = lines[previous].trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.isEmpty { continue }
            guard let range = candidate.range(of: openerPattern, options: .regularExpression),
                  range.lowerBound == candidate.startIndex else { break }
            start = previous
        }
        return start
    }
}
