import Foundation

enum SuggestedPrompts {
    private static let markdownMarkerLength = 3
    private static let maximumFenceIndent = 3

    static let maxPrompts = 4
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

    static func parse(_ text: String) -> [String] {
        prompts(fromLastOf: blocks(in: text))
    }

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

    private static func prompts(fromLastOf found: [Block]) -> [String] {
        guard let last = found.last else { return [] }
        let lines = last.body
            .map { (last.escaped ? decodeEntities($0) : $0).trimmingCharacters(in: promptTrimSet) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty, !lines.contains(where: looksLikeBodyText) else { return [] }
        return prompts(from: lines)
    }

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
            let escaped = line[openerRange].hasPrefix(escapedOpenerPrefix)
            let closerSearch = findCloser(
                in: lines,
                after: index,
                closer: escaped ? escapedCloser : closer
            )
            guard let closer = closerSearch.closerLine else {
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

    private static func nextFence(
        after marker: FenceMarker,
        in fence: (char: Character, length: Int)?
    ) -> (char: Character, length: Int)? {
        guard let open = fence else { return (marker.character, marker.length) }
        let closes = marker.character == open.char && marker.length >= open.length
            && marker.info.trimmingCharacters(in: .whitespaces).isEmpty
        return closes ? nil : open
    }

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

    private static func parsePromptLine(_ line: String) -> String? {
        if let text = afterDelayPrefix(line) {
            return isValidPrompt(text) ? text : nil
        }
        var promptPart = line
        if let afterLabel = SuggestedPromptLinks.textAfterLabel(line) {
            promptPart = afterLabel.trimmingCharacters(in: promptTrimSet)
        }
        if let text = afterDelayPrefix(promptPart) { promptPart = text }
        return isValidPrompt(promptPart) ? promptPart : nil
    }

    private static func afterDelayPrefix(_ text: String) -> String? {
        guard let range = text.range(of: "^delay:[0-9]+\\|", options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let rest = text[range.upperBound...]
        guard !rest.unicodeScalars.contains(where: lineTerminators.contains) else { return nil }
        return String(rest).trimmingCharacters(in: promptTrimSet)
    }

    private static func isValidPrompt(_ text: String) -> Bool {
        !text.isEmpty && SuggestedPromptLinks.visibleText(text).utf16.count <= maxPromptLength
    }
}

private extension SuggestedPrompts {
    static let promptTrimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
    static let lineTerminators = CharacterSet(charactersIn: "\n\r\u{2028}\u{2029}")
    static let namedEntities: [String: String] = ["lt": "<", "gt": ">", "quot": "\"", "apos": "'", "amp": "&"]
    static let maxEntityBodyLength = 8
    static let hexRadix = 16
    static let decimalRadix = 10
    static let maxHexDigits = 6
    static let maxDecimalDigits = 7

    static func decodeEntities(_ line: String) -> String {
        let scalars = Array(line.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let window = scalars[(index + 1)..<min(scalars.count, index + 2 + maxEntityBodyLength)]
            guard scalars[index] == "&", let semicolon = window.firstIndex(of: ";") else {
                out.append(scalars[index])
                index += 1
                continue
            }
            let name = String(String.UnicodeScalarView(scalars[(index + 1)..<semicolon]))
            if let decoded = namedEntities[name] ?? numericReference(name) {
                out.append(contentsOf: decoded.unicodeScalars)
                index = semicolon + 1
            } else {
                out.append(scalars[index])
                index += 1
            }
        }
        return String(out)
    }

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
