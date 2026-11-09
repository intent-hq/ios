import Foundation

/// Minimal Swift lexer for source policy scans: blanks comments and literals,
/// then pairs brackets on the remaining code. See `CopyContextMenuButtonScanner`.
enum SwiftSourceLexer {
    /// Replaces comment, string-literal (interpolations included), and regex
    /// literal bytes with spaces, keeping newlines so offsets and line numbers
    /// survive. `isReliable` is false when a literal or comment never closes.
    static func blankingLiterals(_ bytes: [UInt8]) -> (code: [UInt8], isReliable: Bool) {
        var code = bytes
        var isReliable = true
        var index = 0
        while index < bytes.count {
            let start = index
            if bytes.starts(with: "//", at: index) {
                while index < bytes.count, bytes[index] != Byte.newline { index += 1 }
            } else if bytes.starts(with: "/*", at: index) {
                index = blockCommentEnd(from: index, in: bytes)
                if !bytes.starts(with: "*/", at: index - 2) { isReliable = false }
            } else if let literal = stringLiteralEnd(from: index, in: bytes) ?? regexLiteralEnd(from: index, in: bytes, code: code) {
                index = literal.end
                if !literal.closed { isReliable = false }
            } else {
                index += 1
                continue
            }
            for blank in start..<index where code[blank] != Byte.newline { code[blank] = Byte.space }
        }
        return (code, isReliable)
    }

    /// Bytes after which a `/` starts a regex literal rather than division.
    private static let regexPrefixes = Set("(,=:[{;!&|?".utf8)

    /// End (exclusive) of a `#/…/#` or bare `/…/` regex literal starting at
    /// `start`. A bare literal needs an expression-start byte before it (blanked
    /// `code` so far, skipping whitespace), no whitespace after the opening
    /// slash, and a closing slash on the same line; otherwise `/` is an operator.
    private static func regexLiteralEnd(from start: Int, in bytes: [UInt8], code: [UInt8]) -> (end: Int, closed: Bool)? {
        var index = start
        while index < bytes.count, bytes[index] == Byte.hash { index += 1 }
        let hashes = index - start
        guard index + 1 < bytes.count, bytes[index] == Byte.slash else { return nil }
        if hashes == 0 {
            let previous = skipWhitespaceBackward(from: start - 1, in: code)
            guard previous < 0 || regexPrefixes.contains(code[previous]),
                  !Byte.isWhitespace(bytes[index + 1]), bytes[index + 1] != Byte.slash, bytes[index + 1] != UInt8(ascii: "*")
            else { return nil }
        }
        let closing = [Byte.slash] + Array(repeating: Byte.hash, count: hashes)
        index += 1
        var classDepth = 0
        while index < bytes.count {
            if hashes == 0, bytes[index] == Byte.newline { return nil }
            if bytes[index] == Byte.backslash {
                index += 2
                continue
            }
            if bytes[index] == Byte.openBracket { classDepth += 1 }
            if bytes[index] == Byte.closeBracket, classDepth > 0 { classDepth -= 1 }
            if classDepth == 0, bytes.starts(with: closing, at: index) { return (index + closing.count, true) }
            index += 1
        }
        return (index, false)
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
    /// escapes, and interpolations containing nested literals. A single-line
    /// literal that reaches a newline is reported unclosed and ends there.
    private static func stringLiteralEnd(from start: Int, in bytes: [UInt8]) -> (end: Int, closed: Bool)? {
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
            if bytes.starts(with: closing, at: index) { return (index + closing.count, true) }
            if quotes.count == 1, bytes[index] == Byte.newline { return (index, false) }
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
        return (index, false)
    }

    private static func interpolationEnd(from opener: Int, in bytes: [UInt8]) -> Int {
        var depth = 0
        var index = opener
        while index < bytes.count {
            if let literal = stringLiteralEnd(from: index, in: bytes) {
                index = literal.end
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

    static func skipWhitespace(from start: Int, in code: [UInt8]) -> Int {
        var index = start
        while index < code.count, Byte.isWhitespace(code[index]) { index += 1 }
        return index
    }

    static func skipWhitespaceBackward(from start: Int, in code: [UInt8]) -> Int {
        var index = start
        while index >= 0, Byte.isWhitespace(code[index]) { index -= 1 }
        return index
    }

    static func text(_ bytes: ArraySlice<UInt8>) -> String {
        String(bytes: bytes, encoding: .utf8) ?? ""
    }

    /// Matched `(`/`{`/`[` pairs of blanked code.
    struct Brackets {
        private(set) var closer: [Int: Int] = [:]
        private(set) var opener: [Int: Int] = [:]
        private(set) var isBalanced = true
        private var pairs: [(open: Int, close: Int)] = []

        init(_ code: [UInt8]) {
            let closing = [Byte.openParen: Byte.closeParen, Byte.openBrace: Byte.closeBrace, Byte.openBracket: Byte.closeBracket]
            var stack: [Int] = []
            for (index, byte) in code.enumerated() {
                switch byte {
                case Byte.openParen, Byte.openBrace, Byte.openBracket:
                    stack.append(index)
                case Byte.closeParen, Byte.closeBrace, Byte.closeBracket:
                    guard let open = stack.popLast() else {
                        isBalanced = false
                        continue
                    }
                    if closing[code[open]] != byte { isBalanced = false }
                    closer[open] = index
                    opener[index] = open
                    pairs.append((open, index))
                default:
                    continue
                }
            }
            if !stack.isEmpty { isBalanced = false }
        }

        func enclosingOpeners(of index: Int) -> [Int] {
            pairs.filter { $0.open < index && index < $0.close }.map(\.open)
        }
    }

    enum Byte {
        static let newline = UInt8(ascii: "\n")
        static let space = UInt8(ascii: " ")
        static let quote = UInt8(ascii: "\"")
        static let hash = UInt8(ascii: "#")
        static let backslash = UInt8(ascii: "\\")
        static let dot = UInt8(ascii: ".")
        static let slash = UInt8(ascii: "/")
        static let colon = UInt8(ascii: ":")
        static let comma = UInt8(ascii: ",")
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
