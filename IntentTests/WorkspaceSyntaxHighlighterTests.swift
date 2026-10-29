import Foundation
@testable import Intent
import Testing

struct WorkspaceSyntaxHighlighterTests {
    @Test(arguments: [
        ("Sources/File.SWIFT", "swift"), ("main.py", "python"), ("types.pyi", "python"),
        ("main.go", "go"), ("lib.rs", "rust"), ("data.json", "json"), ("settings.jsonc", "json"),
        ("workflow.yaml", "yaml"), ("workflow.yml", "yaml"), ("Cargo.toml", "ini"), ("config.ini", "ini"),
        ("README.md", "markdown"), ("docs.markdown", "markdown"), ("feed.xml", "xml"),
        ("index.html", "xml"), ("Info.plist", "xml"), ("icon.svg", "xml"),
        ("change.diff", "diff"), ("change.patch", "diff"), ("site.nginx", "nginx"),
        ("etc/nginx.conf", "nginx"), ("home/.gitconfig", "ini"), (".editorconfig", "ini"),
        ("Pipfile", "ini"), ("Cargo.lock", "ini"), ("poetry.lock", "ini"),
        ("uv.lock", "ini"), ("Package.resolved", "json"),
        ("script.js", "javascript"), ("script.mjs", "javascript"), ("script.cjs", "javascript"), ("view.jsx", "javascript"),
        ("script.ts", "typescript"), ("script.mts", "typescript"), ("script.cts", "typescript"), ("view.TSX", "typescript"),
        ("style.css", "css"),
        ("run.sh", "bash"), ("run.bash", "bash"), ("run.zsh", "bash"),
        ("home/.bashrc", "bash"), (".zshrc", "bash"), (".profile", "bash"), (".bash_profile", "bash"), (".zprofile", "bash")
    ])
    func mapsSupportedPaths(_ path: String, expected: String) {
        #expect(WorkspaceSyntaxHighlighter.language(forPath: path) == expected)
    }

    @Test(arguments: ["notes.txt", "style.scss", "style.less", "main.cpp", "Main.kt", "LICENSE", "unknown.conf", "folder.swift/README"])
    func unsupportedPathsNeverAutoDetect(_ path: String) async throws {
        #expect(WorkspaceSyntaxHighlighter.language(forPath: path) == nil)
        let tokens = try await WorkspaceSyntaxHighlighter.highlight(text: "let value = 42 // Swift", path: path)
        #expect(tokens.isEmpty)
    }

    @Test func swiftTokensPreserveUnicodeAndMultilineOffsets() async throws {
        let source = "// café 👩🏽‍💻\r\nlet greeting = \"日本語\"\n/* first\nsecond */\nlet count = 42\n"
        let tokens = try await WorkspaceSyntaxHighlighter.highlight(text: source, path: "example.swift")
        for (scope, snippet) in [("keyword", "let"), ("string", "\"日本語\""), ("number", "42")] {
            let range = NSRange(try #require(source.range(of: snippet)), in: source)
            #expect(tokens.contains { $0.scope == scope && $0.range == range })
        }
        let comments = try tokens
            .filter { $0.scope == "comment" }
            .map { token in String(source[try #require(Range(token.range, in: source))]) }
            .joined()
        #expect(comments.contains("// café 👩🏽‍💻"))
        #expect(comments.contains("/* first\nsecond */"))
        var end = 0
        for token in tokens {
            #expect(token.range.location >= end)
            #expect(token.range.length > 0)
            #expect(NSMaxRange(token.range) <= source.utf16.count)
            end = NSMaxRange(token.range)
        }
    }

    @Test(arguments: [
        ("main.py", "def greet():\n    return \"hello\"\n"),
        ("main.go", "package main\nfunc main() { println(42) }\n"),
        ("main.rs", "fn main() { let value = 42; }\n"),
        ("data.json", "{\"answer\": 42}"),
        ("config.yaml", "name: \"hello\"\n"),
        ("Cargo.toml", "[package]\nname = \"hello\"\n"),
        ("README.md", "# Heading\n\n**Bold** text\n"),
        ("page.html", "<p class=\"greeting\">Hello</p>"),
        ("change.diff", "@@ -1 +1 @@\n-old\n+new\n"),
        ("nginx.conf", "server { listen 80; }\n")
    ])
    func mappedLanguagesProduceUsableRanges(_ path: String, source: String) async throws {
        let tokens = try await WorkspaceSyntaxHighlighter.highlight(text: source, path: path)
        #expect(!tokens.isEmpty)
        #expect(tokens.allSatisfy { $0.range.length > 0 && NSMaxRange($0.range) <= source.utf16.count })
    }

    @Test func emptyAndOversizedSourcesStayPlain() async throws {
        let cap = 256 * 1024
        let prefix = "let value = 42\n"
        let atCap = prefix + String(repeating: " ", count: cap - prefix.utf8.count)
        // Include valid tokens so a mistakenly higher cap cannot pass as plain text.
        for source in ["", atCap + " ", prefix + String(repeating: "é", count: cap / 2)] {
            #expect(try await WorkspaceSyntaxHighlighter.highlight(text: source, path: "large.swift").isEmpty)
        }
        // Inclusive UTF-8 cap: a valid token at the boundary must still highlight.
        #expect(try await !WorkspaceSyntaxHighlighter.highlight(text: atCap, path: "limit.swift").isEmpty)
    }

    @Test func cancelledRequestThrowsInsteadOfPublishingRanges() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WorkspaceSyntaxHighlighter.highlight(text: "let value = 42", path: "main.swift")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        // Cancellation must not poison the shared parser for a later request.
        await #expect(throws: Never.self) {
            let tokens = try await WorkspaceSyntaxHighlighter.highlight(text: "let value = 42", path: "main.swift")
            #expect(!tokens.isEmpty)
        }
    }
}
