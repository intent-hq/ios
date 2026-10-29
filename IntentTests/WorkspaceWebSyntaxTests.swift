import Foundation
@testable import Intent
import Testing

extension WorkspaceSyntaxHighlighterTests {
    @Test(arguments: ["js", "mjs", "cjs", "jsx", "ts", "mts", "cts", "tsx"])
    func scriptTokensKeepExpressionBoundaries(_ suffix: String) async throws {
        let source = #"""
        /** @param {string} name café 👩🏽‍💻 */
        export async function greet(name) {
          const pattern = /a[\/b]+/gi;
          const amount = 0xFF + 1_000n + 2.5e2;
          const message = `日本語 ${name ?? "guest"} ${ { count: 42 }.count }`;
          const nested = `outer ${`inner ${true}`}`;
          // Division is not a regular expression.
          return amount / 2 / 3;
        }
        """#
        let tokens = try await WorkspaceSyntaxHighlighter.highlight(text: source, path: "sample.\(suffix)")
        try assertTokens(tokens, in: source, expected: [
            ("keyword", "export"), ("keyword", "async"), ("title.function", "greet"),
            ("doctag", "@param"), ("type", "{string}"), ("regexp", #"/a[\/b]+/gi"#),
            ("number", "0xFF"), ("number", "1_000n"), ("number", "2.5e2"),
            ("string", #""guest""#), ("number", "42"), ("literal", "true")
        ])
        #expect(tokens.contains { $0.scope == "subst" })
        let division = NSRange(try #require(source.range(of: "amount / 2 / 3")), in: source)
        #expect(!tokens.contains { $0.scope == "regexp" && NSIntersectionRange($0.range, division).length > 0 })
    }

    @Test func typeScriptTypesGenericsAndDecorators() async throws {
        let source = """
        interface Event<T> { value: T; name?: string; count: number; }
        type Result<T> = Promise<Event<T>>;
        @sealed
        class Collector implements Event<string> {
          readonly value: string = "ready";
          public count: number = 12;
        }
        """
        let tokens = try await WorkspaceSyntaxHighlighter.highlight(text: source, path: "collector.ts")
        try assertTokens(tokens, in: source, expected: [
            ("keyword", "interface"), ("title.class", "Event"), ("title.class", "T"),
            ("type", "string"), ("type", "number"), ("keyword", "type"),
            ("meta", "@sealed"), ("title.class", "Collector"), ("keyword", "implements"),
            ("keyword", "readonly"), ("string", "\"ready\"")
        ])
    }

    @Test func stylesheetSelectorsAndDeclarations() async throws {
        let source = """
        /* Layout for café 👩🏽‍💻 */
        @media (min-width: 40rem) {
          #dashboard.card:hover {
            --accent: #336699;
            color: var(--accent);
            padding: 1.5rem;
            display: grid;
            content: "Ready";
          }
        }
        """
        let tokens = try await WorkspaceSyntaxHighlighter.highlight(text: source, path: "layout.css")
        try assertTokens(tokens, in: source, expected: [
            ("comment", "/* Layout for café 👩🏽‍💻 */"), ("keyword", "@media"),
            ("selector-id", "#dashboard"), ("selector-class", ".card"), ("selector-pseudo", ":hover"),
            ("attribute", "color"), ("number", "#336699"), ("number", "1.5rem"),
            ("built_in", "var"), ("variable", "--accent"), ("literal", "grid"), ("string", "\"Ready\"")
        ])
    }

    @Test func shellQuotingSubstitutionsAndHeredoc() async throws {
        let source = #"""
        #!/usr/bin/env bash
        # café 👩🏽‍💻
        if test "$COUNT" -gt 2; then
          echo "${HOME} $(printf '%s' ready)"
          echo '$NOT_EXPANDED'
          cat <<'REPORT'
        A literal $VALUE with "quotes"
        REPORT
          printf 'done'
        fi
        """#
        let tokens = try await WorkspaceSyntaxHighlighter.highlight(text: source, path: "report.sh")
        try assertTokens(tokens, in: source, expected: [
            ("meta", "#!/usr/bin/env bash"), ("comment", "# café 👩🏽‍💻"), ("keyword", "if"),
            ("built_in", "test"), ("variable", "$COUNT"), ("variable", "${HOME}"),
            ("built_in", "printf"), ("string", "'$NOT_EXPANDED'"), ("number", "2"), ("keyword", "fi")
        ])
        #expect(tokens.contains { $0.scope == "subst" })
        let body = NSRange(try #require(source.range(of: "A literal $VALUE with \"quotes\"")), in: source)
        #expect(tokens.contains { $0.scope == "string" && NSIntersectionRange($0.range, body) == body })
    }

    @Test(arguments: [#""don't expand 42""#, #""version 42""#])
    func shellDoubleQuotesKeepApostrophesAndDigitsLiteral(_ quoted: String) async throws {
        let source = "echo " + quoted + "; printf 'done'"
        let tokens = try await WorkspaceSyntaxHighlighter.highlight(text: source, path: "report.sh")
        try assertTokens(tokens, in: source, expected: [
            ("string", quoted), ("built_in", "printf"), ("string", "'done'")
        ])
    }

    @Test(arguments: [("large.js", "const value = `"), ("large.ts", "const pattern = /["), ("large.sh", "cat <<END\n")])
    func malformedScriptsRemainBounded(_ path: String, prefix: String) async throws {
        let source = prefix + String(repeating: "x", count: WorkspaceSyntaxHighlighter.maxBytes - prefix.utf8.count)
        let start = ContinuousClock.now
        let tokens = try await WorkspaceSyntaxHighlighter.highlight(text: source, path: path)
        #expect(start.duration(to: .now) < .seconds(5))
        try assertTokens(tokens, in: source, expected: [])
        #expect(try await WorkspaceSyntaxHighlighter.highlight(text: source + "x", path: path).isEmpty)
    }

    @Test(arguments: ["#!/bin/sh", "#!/usr/bin/bash -e", "#!/usr/bin/env zsh", "#!/usr/bin/env -S bash -eu"])
    func extensionlessShellShebang(_ firstLine: String) async throws {
        let source = firstLine + "\nprintf 'ready'\n"
        #expect(WorkspaceSyntaxHighlighter.language(forPath: "run", firstLine: firstLine) == "bash")
        let tokens = try await WorkspaceSyntaxHighlighter.highlight(text: source, path: "run")
        try assertTokens(tokens, in: source, expected: [("meta", firstLine), ("built_in", "printf"), ("string", "'ready'")])
        #expect(WorkspaceSyntaxHighlighter.language(forPath: "run.py", firstLine: firstLine) == "python")
    }

    @Test(arguments: ["#!/usr/bin/env python", "#!/bin/bashful", "echo '#!/bin/bash'", "# bash"])
    func unknownContentDoesNotBecomeShell(_ source: String) async throws {
        #expect(try await WorkspaceSyntaxHighlighter.highlight(text: source, path: "run").isEmpty)
    }

    private func assertTokens(
        _ tokens: [WorkspaceSyntaxHighlighter.Token], in source: String, expected: [(String, String)]
    ) throws {
        #expect(!tokens.isEmpty)
        var end = 0
        for token in tokens {
            #expect(token.range.location >= end)
            #expect(token.range.length > 0)
            #expect(Range(token.range, in: source) != nil)
            end = NSMaxRange(token.range)
        }
        for (scope, snippet) in expected {
            let range = NSRange(try #require(source.range(of: snippet)), in: source)
            let covered = tokens.filter { $0.scope == scope }.reduce(0) { $0 + NSIntersectionRange($1.range, range).length }
            #expect(covered == range.length, "Expected \(scope) for \(snippet)")
        }
    }
}
