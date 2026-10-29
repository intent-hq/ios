import Foundation
import SwiftHighlight

/// Syntax only: callers keep the original text, font, selection, and theme.
nonisolated enum WorkspaceSyntaxHighlighter {
    struct Token: Equatable, Sendable {
        /// UTF-16 range in the unmodified input, suitable for NSAttributedString.
        let range: NSRange
        /// highlight.js scope, including dotted names such as `title.function`.
        let scope: String
    }

    static let maxBytes = 256 * 1024 // swiftlint:disable:this no_magic_numbers
    private static let engine = Highlight()

    private static let languagesByExtension = [
        "swift": "swift", "py": "python", "pyw": "python", "pyi": "python",
        "go": "go", "rs": "rust", "json": "json", "jsonc": "json", "json5": "json",
        "yaml": "yaml", "yml": "yaml", "toml": "ini", "ini": "ini",
        "md": "markdown", "markdown": "markdown", "xml": "xml", "html": "xml",
        "htm": "xml", "xhtml": "xml", "plist": "xml", "svg": "xml",
        "diff": "diff", "patch": "diff", "nginx": "nginx",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "ts": "typescript", "mts": "typescript", "cts": "typescript", "tsx": "typescript",
        "css": "css", "sh": "bash", "bash": "bash", "zsh": "bash"
    ]
    private static let languagesByFilename = [
        "nginx.conf": "nginx", ".gitconfig": "ini", ".editorconfig": "ini",
        "pipfile": "ini", "cargo.lock": "ini", "poetry.lock": "ini", "uv.lock": "ini",
        "package.resolved": "json", ".bashrc": "bash", ".zshrc": "bash", ".profile": "bash",
        ".bash_profile": "bash", ".zprofile": "bash"
    ]

    /// Explicit paths take precedence; a shell shebang is the only content hint.
    static func language(forPath path: String, firstLine: String? = nil) -> String? {
        let url = URL(fileURLWithPath: path)
        let filename = url.lastPathComponent.lowercased()
        if let language = languagesByFilename[filename] { return language }
        let fileExtension = url.pathExtension.lowercased()
        if let language = languagesByExtension[fileExtension] { return language }
        guard let firstLine, firstLine.range(
            of: #"\A#![\t ]*(?:/[^\s]+/)?(?:sh|bash|zsh)(?:\s|$)|\A#![\t ]*/usr/bin/env[\t ]+(?:-S[\t ]+)?(?:sh|bash|zsh)(?:\s|$)"#,
            options: .regularExpression
        ) != nil else { return nil }
        return "bash"
    }

    /// Returns ordered, non-overlapping ranges. Unsupported, empty, oversized,
    /// or failed parses return no ranges; cancellation throws CancellationError.
    /// Both parsing and range conversion run away from the calling UI actor.
    @concurrent
    static func highlight(text: String, path: String) async throws -> [Token] {
        try Task.checkCancellation()
        guard !text.isEmpty, text.utf8.count <= maxBytes else { return [] }
        let firstLine = String(text.prefix(512).prefix { $0 != "\n" }) // swiftlint:disable:this no_magic_numbers
        guard let language = language(forPath: path, firstLine: firstLine) else { return [] }
        let result = try await engine.parseWorkspaceText(text, language: language)
        try Task.checkCancellation()
        guard result.errorRaised == nil else { return [] }
        return try tokens(in: result.tokenTree, matching: text)
    }

    private static func tokens(in tree: TokenTree, matching source: String) throws -> [Token] {
        var pending: [(node: TokenNode, scope: String?)] = [(.scope(tree.root), nil)]
        var tokens: [Token] = []
        var reconstructed = ""
        reconstructed.reserveCapacity(source.utf8.count)
        var offset = 0
        while let item = pending.popLast() {
            try Task.checkCancellation()
            switch item.node {
            case .text(let text):
                let length = text.utf16.count
                if let scope = item.scope, length > 0 {
                    tokens.append(Token(range: NSRange(location: offset, length: length), scope: scope))
                }
                offset += length
                reconstructed.append(text)
            case .scope(let node):
                let scope = node.scope ?? item.scope
                pending.append(contentsOf: node.children.reversed().map { ($0, scope) })
            }
        }
        try Task.checkCancellation()
        // Never apply shifted ranges if the early-stage parser drops or rewrites
        // text (including embedded-language markup). Byte equality is deliberate:
        // canonically equivalent Unicode can have different UTF-16 offsets.
        guard reconstructed.utf8.elementsEqual(source.utf8) else { return [] }
        return tokens
    }
}

private extension Highlight {
    static let workspaceLanguages: [String: @Sendable (Highlight) -> Language] = [
        "diff": diffLanguage, "go": goLanguage, "ini": iniLanguage, "json": jsonLanguage,
        "markdown": markdownLanguage, "nginx": nginxLanguage, "python": pythonLanguage,
        "rust": rustLanguage, "swift": swiftLanguage, "xml": xmlLanguage, "yaml": yamlLanguage,
        "javascript": WorkspaceScriptLanguages.javascript, "typescript": WorkspaceScriptLanguages.typescript,
        "css": WorkspaceStylesheetLanguage.css, "bash": WorkspaceShellLanguage.bash
    ]

    /// Keep registration, the compiled grammar cache, and parsing on one actor.
    /// Checking here also prevents cancelled queued requests from starting a parse.
    func parseWorkspaceText(_ text: String, language: String) throws -> ParseResult {
        try Task.checkCancellation()
        if getLanguage(language) == nil, let definition = Self.workspaceLanguages[language] {
            registerLanguage(language, definition: definition)
        }
        try Task.checkCancellation()
        // SwiftHighlight has no cancellation hook inside its synchronous parser.
        // Bound the input above and discard cancelled work immediately afterward.
        let result = parse(text, language: language)
        try Task.checkCancellation()
        return result
    }
}
