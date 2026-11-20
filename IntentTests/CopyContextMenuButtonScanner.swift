import Foundation

enum CopyContextMenuButtonScanner {
    private typealias Byte = SwiftSourceLexer.Byte

    struct Finding: Hashable, Comparable {
        let line: Int
        let source: String

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.line < rhs.line }
    }

    static let marker = "copyContextMenuPassthrough"

    private static let passthroughStyle =
        #"^\(\s*IntentButtonStyle\s*\((?:[^()]*,\s*)?passesThroughCopyMenu\s*:\s*true\s*(?:,[^()]*)?\)\s*\)$"#

    static let detachedContainers: Set<String> = [
        "Menu", "Preview", "ToolbarItem", "ToolbarItemGroup",
        "accessibilityActions", "alert", "confirmationDialog", "contextMenu", "fullScreenCover",
        "navigationDestination", "popover", "sheet", "swipeActions", "toolbar"
    ]

    struct Scan {
        let findings: [Finding]
        let isReliable: Bool
    }

    static func unmarkedButtons(in source: String) -> [Finding] {
        scan(source).findings
    }

    static func scan(_ source: String) -> Scan {
        let (code, lexed) = SwiftSourceLexer.blankingLiterals(Array(source.utf8))
        let brackets = SwiftSourceLexer.Brackets(code)
        let helpers = markedHelpers(in: code, brackets: brackets)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let calls = buttonStarts(in: code).map { parseCall(from: $0, in: code, brackets: brackets) }

        let findings = calls.compactMap { call -> Finding? in
            let detached = brackets.enclosingOpeners(of: call.start).contains { opener in
                detachedContainers.contains(calleeName(before: opener, in: code, brackets: brackets))
            }
            guard !detached else { return nil }
            let marked = call.labels.contains { label in
                reachesMarker(labelText(label, excluding: calls, in: code), helpers: helpers)
            } || hasPassthroughStyle(after: call.end, in: code, brackets: brackets)
            guard !marked else { return nil }
            let line = code[..<call.start].count { $0 == Byte.newline } + 1
            return Finding(line: line, source: lines[line - 1].trimmingCharacters(in: .whitespaces))
        }
        return Scan(findings: findings, isReliable: lexed && brackets.isBalanced)
    }

    private static func labelText(_ label: Range<Int>, excluding calls: [ButtonCall], in code: [UInt8]) -> String {
        var bytes = Array(code[label])
        for nested in calls where label.contains(nested.start) {
            for index in nested.start..<min(nested.end, label.upperBound) {
                bytes[index - label.lowerBound] = Byte.space
            }
        }
        return SwiftSourceLexer.text(bytes[...])
    }

    private static func reachesMarker(_ text: String, helpers: Set<String>) -> Bool {
        text.contains(marker) || helpers.contains { references(text, name: $0) }
    }

    private static func references(_ text: String, name: String) -> Bool {
        text.range(of: #"(?<![.\w])"# + name + #"\b(?!\s*:)"#, options: .regularExpression) != nil
    }

    private static func markedHelpers(in code: [UInt8], brackets: SwiftSourceLexer.Brackets) -> Set<String> {
        let declarations = Dictionary(grouping: helperDeclarations(in: code, brackets: brackets), by: \.name)
        var marked: Set<String> = []
        var changed = true
        while changed {
            changed = false
            for (name, bodies) in declarations where !marked.contains(name)
                && bodies.allSatisfy({ reachesMarker($0.body, helpers: marked) }) {
                marked.insert(name)
                changed = true
            }
        }
        return marked
    }

    private static func helperDeclarations(in code: [UInt8], brackets: SwiftSourceLexer.Brackets) -> [(name: String, body: String)] {
        let source = SwiftSourceLexer.text(code[...])
        let pattern = try? NSRegularExpression(pattern: #"\b(func|var|struct)\s+(\w+)"#)
        let matches = pattern?.matches(in: source, range: NSRange(source.startIndex..., in: source)) ?? []
        return matches.compactMap { match in
            guard let kindRange = Range(match.range(at: 1), in: source),
                  let nameRange = Range(match.range(at: 2), in: source) else { return nil }
            let nameEnd = source.utf8.distance(from: source.startIndex, to: nameRange.upperBound)
            guard let opener = bodyOpener(after: nameEnd, kind: source[kindRange], in: code, brackets: brackets),
                  let closer = brackets.closer[opener] else { return nil }
            return (String(source[nameRange]), SwiftSourceLexer.text(code[opener...closer]))
        }
    }

    private static func bodyOpener(after index: Int, kind: Substring, in code: [UInt8], brackets: SwiftSourceLexer.Brackets) -> Int? {
        var cursor = index
        while cursor < code.count {
            switch code[cursor] {
            case Byte.openBrace:
                return cursor
            case Byte.openParen where kind == "func":
                guard let closer = brackets.closer[cursor] else { return nil }
                cursor = closer
            case Byte.newline where kind == "var", Byte.equals, Byte.closeBrace:
                return nil
            default:
                break
            }
            cursor += 1
        }
        return nil
    }

    private static func hasPassthroughStyle(after end: Int, in code: [UInt8], brackets: SwiftSourceLexer.Brackets) -> Bool {
        guard let style = chainedModifiers(after: end, in: code, brackets: brackets).first(where: { $0.name == "buttonStyle" }),
              let arguments = style.arguments else { return false }
        return SwiftSourceLexer.text(code[arguments]).range(of: passthroughStyle, options: .regularExpression) != nil
    }

    private static func chainedModifiers(
        after end: Int,
        in code: [UInt8],
        brackets: SwiftSourceLexer.Brackets
    ) -> [(name: String, arguments: Range<Int>?)] {
        var modifiers: [(name: String, arguments: Range<Int>?)] = []
        var cursor = end
        while true {
            let dot = SwiftSourceLexer.skipWhitespace(from: cursor, in: code)
            guard dot < code.count, code[dot] == Byte.dot else { break }
            var nameEnd = dot + 1
            while nameEnd < code.count, Byte.isIdentifier(code[nameEnd]) { nameEnd += 1 }
            guard nameEnd > dot + 1 else { break }
            cursor = nameEnd
            var arguments: Range<Int>?
            let paren = SwiftSourceLexer.skipWhitespace(from: cursor, in: code)
            if paren < code.count, code[paren] == Byte.openParen, let closer = brackets.closer[paren] {
                arguments = paren..<(closer + 1)
                cursor = closer + 1
            }
            cursor = trailingClosures(from: cursor, in: code, brackets: brackets).end
            modifiers.append((SwiftSourceLexer.text(code[(dot + 1)..<nameEnd]), arguments))
        }
        return modifiers
    }

    private static let buttonName = Array("Button".utf8)
    private static let moduleQualifier = Array("SwiftUI.".utf8)

    private struct ButtonCall {
        let start: Int
        let end: Int
        let labels: [Range<Int>]
    }

    private static func buttonStarts(in code: [UInt8]) -> [Int] {
        var starts: [Int] = []
        var index = 0
        while index + buttonName.count <= code.count {
            defer { index += 1 }
            guard code[index..<index + buttonName.count].elementsEqual(buttonName) else { continue }
            if index > 0, Byte.isIdentifier(code[index - 1]) { continue }
            if index > 0, code[index - 1] == Byte.dot {
                let qualifier = index - moduleQualifier.count
                guard qualifier >= 0, code[qualifier..<index].elementsEqual(moduleQualifier),
                      qualifier == 0 || !Byte.isIdentifier(code[qualifier - 1]) else { continue }
            }
            let next = SwiftSourceLexer.skipWhitespace(from: index + buttonName.count, in: code)
            guard next < code.count, code[next] == Byte.openParen || code[next] == Byte.openBrace else { continue }
            starts.append(index)
        }
        return starts
    }

    private static func parseCall(from start: Int, in code: [UInt8], brackets: SwiftSourceLexer.Brackets) -> ButtonCall {
        var end = start + buttonName.count
        let cursor = SwiftSourceLexer.skipWhitespace(from: end, in: code)
        var argumentRange: Range<Int>?
        if cursor < code.count, code[cursor] == Byte.openParen, let closer = brackets.closer[cursor] {
            argumentRange = cursor..<(closer + 1)
            end = closer + 1
        }
        let (closures, closuresEnd) = trailingClosures(from: end, in: code, brackets: brackets)

        var labels = closures.filter { $0.label == "label" }.map(\.range)
        let label = argumentRange.flatMap { argumentValue("label", in: $0, code: code, brackets: brackets) }
        if let label { labels.append(label) }
        let hasAction = argumentRange.flatMap { argumentValue("action", in: $0, code: code, brackets: brackets) } != nil
        if labels.isEmpty, hasAction, let first = closures.first, first.label == nil {
            labels.append(first.range)
        }
        return ButtonCall(start: start, end: closuresEnd, labels: labels)
    }

    private static func trailingClosures(
        from start: Int,
        in code: [UInt8],
        brackets: SwiftSourceLexer.Brackets
    ) -> (closures: [(label: String?, range: Range<Int>)], end: Int) {
        var closures: [(label: String?, range: Range<Int>)] = []
        var end = start
        while true {
            var cursor = SwiftSourceLexer.skipWhitespace(from: end, in: code)
            var labelEnd = cursor
            while labelEnd < code.count, Byte.isIdentifier(code[labelEnd]) { labelEnd += 1 }
            var label: String?
            if labelEnd > cursor {
                let colon = SwiftSourceLexer.skipWhitespace(from: labelEnd, in: code)
                guard colon < code.count, code[colon] == Byte.colon else { break }
                label = SwiftSourceLexer.text(code[cursor..<labelEnd])
                cursor = SwiftSourceLexer.skipWhitespace(from: colon + 1, in: code)
            }
            guard cursor < code.count, code[cursor] == Byte.openBrace, let closer = brackets.closer[cursor] else { break }
            closures.append((label, cursor..<(closer + 1)))
            end = closer + 1
        }
        return (closures, end)
    }

    private static func argumentValue(
        _ name: String,
        in arguments: Range<Int>,
        code: [UInt8],
        brackets: SwiftSourceLexer.Brackets
    ) -> Range<Int>? {
        let closeParen = arguments.upperBound - 1
        var segmentStart = arguments.lowerBound + 1
        var cursor = segmentStart
        while cursor <= closeParen {
            if cursor == closeParen || code[cursor] == Byte.comma {
                if let value = labeledValue(name, in: segmentStart..<cursor, code: code) { return value }
                segmentStart = cursor + 1
            } else if let closer = brackets.closer[cursor] {
                cursor = closer
            }
            cursor += 1
        }
        return nil
    }

    private static func labeledValue(_ name: String, in segment: Range<Int>, code: [UInt8]) -> Range<Int>? {
        let nameBytes = Array(name.utf8)
        let start = SwiftSourceLexer.skipWhitespace(from: segment.lowerBound, in: code)
        let nameEnd = start + nameBytes.count
        guard nameEnd <= segment.upperBound, code[start..<nameEnd].elementsEqual(nameBytes),
              nameEnd == segment.upperBound || !Byte.isIdentifier(code[nameEnd]) else { return nil }
        let colon = SwiftSourceLexer.skipWhitespace(from: nameEnd, in: code)
        guard colon < segment.upperBound, code[colon] == Byte.colon else { return nil }
        return (colon + 1)..<segment.upperBound
    }

    private static func calleeName(before opener: Int, in code: [UInt8], brackets: SwiftSourceLexer.Brackets) -> String {
        var cursor = SwiftSourceLexer.skipWhitespaceBackward(from: opener - 1, in: code)
        if code[opener] == Byte.openBrace, cursor >= 0, code[cursor] == Byte.closeParen,
           let argumentsOpener = brackets.opener[cursor] {
            cursor = SwiftSourceLexer.skipWhitespaceBackward(from: argumentsOpener - 1, in: code)
        }
        var end = cursor + 1
        while cursor >= 0, Byte.isIdentifier(code[cursor]) { cursor -= 1 }
        if end == cursor + 1, cursor >= 0, code[cursor] == Byte.colon {
            cursor = SwiftSourceLexer.skipWhitespaceBackward(from: cursor - 1, in: code)
            end = cursor + 1
            while cursor >= 0, Byte.isIdentifier(code[cursor]) { cursor -= 1 }
        }
        return SwiftSourceLexer.text(code[(cursor + 1)..<end])
    }
}
