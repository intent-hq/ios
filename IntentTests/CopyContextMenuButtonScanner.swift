import Foundation

/// Source scanner behind `CopyContextMenuPassthroughPolicyTests`.
///
/// It finds `Button` calls that render inline in a view and reports each one
/// whose label never reaches `copyContextMenuPassthrough()`, directly or
/// through a same-file helper (`func`, `var`, or `struct`) that applies it.
/// The label is the `label:` closure or argument, or the trailing closure of
/// `Button(action:)`; a title-only Button has none. A marker on the action,
/// on a nested Button, or on the Button's own modifier chain does not count:
/// it must sit inside the label so the Button is its SwiftUI ancestor (see
/// `CopyContextMenuPassthroughMarker`).
/// Buttons inside menus, dialogs, toolbars, and presented or pushed screens
/// are skipped because they never render under the row's overlay.
///
/// The scan is lexical: comments, string literals, and regex literals are
/// blanked first, then brackets are matched on what remains.
enum CopyContextMenuButtonScanner {
    private typealias Byte = SwiftSourceLexer.Byte

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

    struct Scan {
        let findings: [Finding]
        /// False when a literal is unterminated or brackets do not pair up after
        /// lexing: the lexer misread a construct, so findings cannot be trusted.
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
            }
            guard !marked else { return nil }
            let line = code[..<call.start].count { $0 == Byte.newline } + 1
            return Finding(line: line, source: lines[line - 1].trimmingCharacters(in: .whitespaces))
        }
        return Scan(findings: findings, isReliable: lexed && brackets.isBalanced)
    }

    /// Label source with nested Button calls blanked, so their markers do not
    /// count for the outer Button.
    private static func labelText(_ label: Range<Int>, excluding calls: [ButtonCall], in code: [UInt8]) -> String {
        var bytes = Array(code[label])
        for nested in calls where label.contains(nested.start) {
            for index in nested.start..<min(nested.end, label.upperBound) {
                bytes[index - label.lowerBound] = Byte.space
            }
        }
        return SwiftSourceLexer.text(bytes[...])
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
    /// A name counts only when every same-file declaration of it is marked, so
    /// a common helper name (`header`, `label`) in two types cannot vouch for
    /// the unmarked one.
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

    /// Opening brace of a declaration's body; nil for stored properties and
    /// requirements without a body.
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

    // MARK: - Button calls

    private static let buttonName = Array("Button".utf8)
    private static let moduleQualifier = Array("SwiftUI.".utf8)

    private struct ButtonCall {
        let start: Int
        /// End (exclusive) of the argument list and every trailing closure.
        let end: Int
        let labels: [Range<Int>]
    }

    /// Offsets of `Button(` / `Button {` calls (optionally `SwiftUI.`-qualified),
    /// excluding longer identifiers (`IntentIconButton`) and other member accesses.
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
        var cursor = SwiftSourceLexer.skipWhitespace(from: end, in: code)
        var arguments = ""
        var argumentRange: Range<Int>?
        if cursor < code.count, code[cursor] == Byte.openParen, let closer = brackets.closer[cursor] {
            argumentRange = cursor..<(closer + 1)
            arguments = SwiftSourceLexer.text(code[cursor...closer])
            end = closer + 1
        }
        var closures: [(label: String?, range: Range<Int>)] = []
        while true {
            cursor = SwiftSourceLexer.skipWhitespace(from: end, in: code)
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

        var labels = closures.filter { $0.label == "label" }.map(\.range)
        if let argumentRange, hasArgument("label", in: arguments) { labels.append(argumentRange) }
        if labels.isEmpty, hasArgument("action", in: arguments), let first = closures.first, first.label == nil {
            labels.append(first.range)
        }
        return ButtonCall(start: start, end: end, labels: labels)
    }

    private static func hasArgument(_ name: String, in arguments: String) -> Bool {
        arguments.range(of: #"\b"# + name + #"\s*:"#, options: .regularExpression) != nil
    }

    /// Name of the call or modifier that owns `opener`: `alert` for both
    /// `.alert(…) {` and `.alert(…, actions: {`, `Menu` for `Menu {`.
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
