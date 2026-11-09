import Foundation

/// Source scanner behind `CopyContextMenuPassthroughPolicyTests`.
///
/// It finds `Button` calls that render inline in a view and reports each one
/// whose call (arguments plus trailing closures) never reaches
/// `copyContextMenuPassthrough()`, directly or through a same-file helper
/// (`func`, `var`, or `struct`) that applies it. A marker on the Button's own
/// modifier chain does not count: the marker must sit inside the label so the
/// Button is its SwiftUI ancestor (see `CopyContextMenuPassthroughMarker`).
/// Buttons inside menus, dialogs, toolbars, and presented or pushed screens
/// are skipped because they never render under the row's overlay.
///
/// The scan is lexical: comments and string literals are blanked first, then
/// brackets are matched on what remains.
enum CopyContextMenuButtonScanner {
    struct Finding: Hashable, Comparable {
        let line: Int
        let source: String

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.line < rhs.line }
    }

    static let marker = "copyContextMenuPassthrough"

    /// Callees whose closures render outside the row's view hierarchy.
    static let detachedContainers: Set<String> = [
        "Menu", "Preview", "ToolbarItem", "ToolbarItemGroup",
        "accessibilityActions", "alert", "confirmationDialog", "contextMenu", "fullScreenCover",
        "navigationDestination", "popover", "sheet", "swipeActions", "toolbar"
    ]

    static func unmarkedButtons(in source: String) -> [Finding] {
        let original = Array(source.utf8)
        let code = blankingCommentsAndStrings(original)
        let brackets = Brackets(code)
        let helpers = markedHelpers(in: code, brackets: brackets)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)

        return buttonStarts(in: code).compactMap { start in
            let detached = brackets.enclosingOpeners(of: start).contains { opener in
                detachedContainers.contains(calleeName(before: opener, in: code, brackets: brackets))
            }
            guard !detached else { return nil }
            let call = text(code[start..<callEnd(from: start, in: code, brackets: brackets)])
            guard !reachesMarker(call, helpers: helpers) else { return nil }
            let line = code[..<start].count { $0 == Byte.newline } + 1
            return Finding(line: line, source: lines[line - 1].trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: - Marker reachability

    private static func reachesMarker(_ text: String, helpers: Set<String>) -> Bool {
        text.contains(marker) || helpers.contains { references(text, name: $0) }
    }

    /// A bare use of `name`: not a member access, argument label, or longer identifier.
    private static func references(_ text: String, name: String) -> Bool {
        text.range(of: #"(?<![.\w])"# + name + #"\b(?!\s*:)"#, options: .regularExpression) != nil
    }

    /// Same-file declarations whose bodies apply the marker, directly or via
    /// another marked declaration.
    private static func markedHelpers(in code: [UInt8], brackets: Brackets) -> Set<String> {
        let declarations = helperDeclarations(in: code, brackets: brackets)
        var marked = Set(declarations.filter { $0.body.contains(marker) }.map(\.name))
        var changed = true
        while changed {
            changed = false
            for declaration in declarations where !marked.contains(declaration.name)
                && marked.contains(where: { references(declaration.body, name: $0) }) {
                marked.insert(declaration.name)
                changed = true
            }
        }
        return marked
    }

    private static func helperDeclarations(in code: [UInt8], brackets: Brackets) -> [(name: String, body: String)] {
        let source = text(code[...])
        let pattern = try? NSRegularExpression(pattern: #"\b(func|var|struct)\s+(\w+)"#)
        let matches = pattern?.matches(in: source, range: NSRange(source.startIndex..., in: source)) ?? []
        return matches.compactMap { match in
            guard let kindRange = Range(match.range(at: 1), in: source),
                  let nameRange = Range(match.range(at: 2), in: source) else { return nil }
            let nameEnd = source.utf8.distance(from: source.startIndex, to: nameRange.upperBound)
            guard let opener = bodyOpener(after: nameEnd, kind: source[kindRange], in: code, brackets: brackets),
                  let closer = brackets.closer[opener] else { return nil }
            return (String(source[nameRange]), text(code[opener...closer]))
        }
    }

    /// Opening brace of a declaration's body; nil for stored properties and
    /// requirements without a body.
    private static func bodyOpener(after index: Int, kind: Substring, in code: [UInt8], brackets: Brackets) -> Int? {
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

    // MARK: - Button calls

    private static let buttonName = Array("Button".utf8)

    /// Offsets of `Button(` / `Button {` calls, excluding longer identifiers
    /// (`IntentIconButton`) and member accesses.
    private static func buttonStarts(in code: [UInt8]) -> [Int] {
        var starts: [Int] = []
        var index = 0
        while index + buttonName.count <= code.count {
            defer { index += 1 }
            guard code[index..<index + buttonName.count].elementsEqual(buttonName) else { continue }
            if index > 0, Byte.isIdentifier(code[index - 1]) || code[index - 1] == Byte.dot { continue }
            let next = skipWhitespace(from: index + buttonName.count, in: code)
            guard next < code.count, code[next] == Byte.openParen || code[next] == Byte.openBrace else { continue }
            starts.append(index)
        }
        return starts
    }

    /// End (exclusive) of the call: its argument list plus every unlabeled or
    /// labeled (`label:`) trailing closure.
    private static func callEnd(from start: Int, in code: [UInt8], brackets: Brackets) -> Int {
        var end = start + buttonName.count
        var cursor = skipWhitespace(from: end, in: code)
        if cursor < code.count, code[cursor] == Byte.openParen, let closer = brackets.closer[cursor] {
            end = closer + 1
        }
        while true {
            cursor = skipWhitespace(from: end, in: code)
            var labelEnd = cursor
            while labelEnd < code.count, Byte.isIdentifier(code[labelEnd]) { labelEnd += 1 }
            if labelEnd > cursor {
                let colon = skipWhitespace(from: labelEnd, in: code)
                guard colon < code.count, code[colon] == Byte.colon else { return end }
                cursor = skipWhitespace(from: colon + 1, in: code)
            }
            guard cursor < code.count, code[cursor] == Byte.openBrace, let closer = brackets.closer[cursor] else {
                return end
            }
            end = closer + 1
        }
    }

    /// Name of the call or modifier that owns `opener`: `alert` for both
    /// `.alert(…) {` and `.alert(…, actions: {`, `Menu` for `Menu {`.
    private static func calleeName(before opener: Int, in code: [UInt8], brackets: Brackets) -> String {
        var cursor = skipWhitespaceBackward(from: opener - 1, in: code)
        if code[opener] == Byte.openBrace, cursor >= 0, code[cursor] == Byte.closeParen,
           let argumentsOpener = brackets.opener[cursor] {
            cursor = skipWhitespaceBackward(from: argumentsOpener - 1, in: code)
        }
        var end = cursor + 1
        while cursor >= 0, Byte.isIdentifier(code[cursor]) { cursor -= 1 }
        if end == cursor + 1, cursor >= 0, code[cursor] == Byte.colon {
            cursor = skipWhitespaceBackward(from: cursor - 1, in: code)
            end = cursor + 1
            while cursor >= 0, Byte.isIdentifier(code[cursor]) { cursor -= 1 }
        }
        return text(code[(cursor + 1)..<end])
    }

    // MARK: - Lexing

    /// Replaces comment and string-literal bytes (interpolations included)
    /// with spaces, keeping newlines so offsets and line numbers survive.
    static func blankingCommentsAndStrings(_ bytes: [UInt8]) -> [UInt8] {
        var code = bytes
        var index = 0
        while index < bytes.count {
            let start = index
            if bytes.starts(with: "//", at: index) {
                while index < bytes.count, bytes[index] != Byte.newline { index += 1 }
            } else if bytes.starts(with: "/*", at: index) {
                index = blockCommentEnd(from: index, in: bytes)
            } else if let end = stringLiteralEnd(from: index, in: bytes) {
                index = end
            } else {
                index += 1
                continue
            }
            for blank in start..<index where code[blank] != Byte.newline { code[blank] = Byte.space }
        }
        return code
    }

    private static func blockCommentEnd(from start: Int, in bytes: [UInt8]) -> Int {
        var depth = 0
        var index = start
        while index < bytes.count {
            if bytes.starts(with: "/*", at: index) {
                depth += 1
                index += 2
            } else if bytes.starts(with: "*/", at: index) {
                depth -= 1
                index += 2
                if depth == 0 { return index }
            } else {
                index += 1
            }
        }
        return index
    }

    /// End (exclusive) of the string literal starting at `start`, or nil when
    /// no literal starts there. Handles `#` delimiters, multi-line literals,
    /// escapes, and interpolations containing nested literals.
    private static func stringLiteralEnd(from start: Int, in bytes: [UInt8]) -> Int? {
        var index = start
        while index < bytes.count, bytes[index] == Byte.hash { index += 1 }
        let hashes = index - start
        guard index < bytes.count, bytes[index] == Byte.quote else { return nil }
        let multiline = Array("\"\"\"".utf8)
        let quotes = bytes.starts(with: multiline, at: index) ? multiline : [Byte.quote]
        index += quotes.count
        let closing = quotes + Array(repeating: Byte.hash, count: hashes)
        let escape = [Byte.backslash] + Array(repeating: Byte.hash, count: hashes)
        while index < bytes.count {
            if bytes.starts(with: closing, at: index) { return index + closing.count }
            if bytes.starts(with: escape, at: index) {
                index += escape.count
                if index < bytes.count, bytes[index] == Byte.openParen {
                    index = interpolationEnd(from: index, in: bytes)
                } else {
                    index += 1
                }
            } else {
                index += 1
            }
        }
        return index
    }

    private static func interpolationEnd(from opener: Int, in bytes: [UInt8]) -> Int {
        var depth = 0
        var index = opener
        while index < bytes.count {
            if let end = stringLiteralEnd(from: index, in: bytes) {
                index = end
                continue
            }
            if bytes[index] == Byte.openParen { depth += 1 }
            if bytes[index] == Byte.closeParen {
                depth -= 1
                if depth == 0 { return index + 1 }
            }
            index += 1
        }
        return index
    }

    private static func skipWhitespace(from start: Int, in code: [UInt8]) -> Int {
        var index = start
        while index < code.count, Byte.isWhitespace(code[index]) { index += 1 }
        return index
    }

    private static func skipWhitespaceBackward(from start: Int, in code: [UInt8]) -> Int {
        var index = start
        while index >= 0, Byte.isWhitespace(code[index]) { index -= 1 }
        return index
    }

    private static func text(_ bytes: ArraySlice<UInt8>) -> String {
        String(bytes: bytes, encoding: .utf8) ?? ""
    }

    /// Matched `(`/`{`/`[` pairs of blanked code.
    private struct Brackets {
        private(set) var closer: [Int: Int] = [:]
        private(set) var opener: [Int: Int] = [:]
        private var pairs: [(open: Int, close: Int)] = []

        init(_ code: [UInt8]) {
            var stack: [Int] = []
            for (index, byte) in code.enumerated() {
                switch byte {
                case Byte.openParen, Byte.openBrace, Byte.openBracket:
                    stack.append(index)
                case Byte.closeParen, Byte.closeBrace, Byte.closeBracket:
                    guard let open = stack.popLast() else { continue }
                    closer[open] = index
                    opener[index] = open
                    pairs.append((open, index))
                default:
                    continue
                }
            }
        }

        func enclosingOpeners(of index: Int) -> [Int] {
            pairs.filter { $0.open < index && index < $0.close }.map(\.open)
        }
    }

    private enum Byte {
        static let newline = UInt8(ascii: "\n")
        static let space = UInt8(ascii: " ")
        static let quote = UInt8(ascii: "\"")
        static let hash = UInt8(ascii: "#")
        static let backslash = UInt8(ascii: "\\")
        static let dot = UInt8(ascii: ".")
        static let colon = UInt8(ascii: ":")
        static let equals = UInt8(ascii: "=")
        static let openParen = UInt8(ascii: "(")
        static let closeParen = UInt8(ascii: ")")
        static let openBrace = UInt8(ascii: "{")
        static let closeBrace = UInt8(ascii: "}")
        static let openBracket = UInt8(ascii: "[")
        static let closeBracket = UInt8(ascii: "]")

        static func isIdentifier(_ byte: UInt8) -> Bool {
            byte == UInt8(ascii: "_") || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
        }

        static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == space || byte == newline || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r")
        }
    }
}

private extension Array where Element == UInt8 {
    func starts(with prefix: String, at index: Int) -> Bool {
        starts(with: Array(prefix.utf8), at: index)
    }

    func starts(with prefix: [UInt8], at index: Int) -> Bool {
        index + prefix.count <= count && self[index..<index + prefix.count].elementsEqual(prefix)
    }
}
