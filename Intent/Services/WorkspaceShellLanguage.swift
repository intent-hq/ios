import SwiftHighlight

/// Adapted from highlight.js 11.11.1 bash (BSD-3-Clause; see Acknowledgements).
nonisolated enum WorkspaceShellLanguage {
    static func bash(_: Highlight) -> Language {
        let keywords = HLJS.kw(
            pattern: .string(#"\b[a-z][a-z0-9._-]*\b"#),
            keyword: words("if then else elif fi time for while until in do done case esac coproc function select"),
            literal: ["true", "false"],
            builtIn: words("""
                break cd continue eval exec exit export getopts hash pwd readonly return shift test times trap umask unset
                alias bind builtin caller command declare echo enable help let local logout mapfile printf read readarray
                source type typeset ulimit unalias set shopt autoload bg bindkey chdir dirs disable disown emulate fc fg
                float functions history integer jobs kill limit noglob popd print pushd rehash setopt stat suspend
                unfunction unhash unlimit unsetopt wait whence where which zcompile zmodload zparseopts zstyle
                cat chmod cp cut date dirname env find grep head mkdir mktemp mv rm sed sort tail tee touch tr uname uniq wc
                """)
        )
        let variable = Mode(scope: "variable", match: .string(#"\$(?:[A-Za-z_][A-Za-z0-9_]*|[0-9]+|[?#@$!*-])"#))
        let braced = Mode(scope: "variable", begin: .string(#"\$\{"#), end: .string(#"\}"#), contains: [.self, .mode(variable)])
        let single = Mode(scope: "string", begin: .string("'"), end: .string("'"))
        let number = Mode(scope: "number", match: .string(#"\b[0-9]+(?:#[0-9a-fA-F]+)?\b"#))
        let comment = Mode(scope: "comment", match: .string(#"(?<!\S)#[^\r\n]*"#))
        let interpolation: [ModeReference] = [.mode(Highlight.backslashEscape), .mode(variable), .mode(braced)]
        let base = interpolation + [.mode(single), .mode(number)]
        let innerQuote = Mode(scope: "string", begin: .string("\""), end: .string("\""), contains: interpolation)
        let substitution = Mode(
            scope: "subst",
            begin: .string(#"\$\("#),
            end: .string(#"\)"#),
            keywords: keywords,
            contains: [.self, .mode(innerQuote), .mode(comment)] + base
        )
        let double = Mode(scope: "string", begin: .string("\""), end: .string("\""), contains: interpolation + [.mode(substitution)])
        let backtick = Mode(scope: "subst", begin: .string("`"), end: .string("`"), keywords: keywords, contains: base)
        // A whole match preserves arbitrary delimiters without mutable callback
        // state (the Mode callback API does not expose per-parse captures).
        let heredoc = Mode(scope: "string", match: .string(#"<<-?[\t ]*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?[^\r\n]*\r?\n[\s\S]*?^\t*\1(?=\r?$)"#))
        return Language(name: "Bash", keywords: keywords, contains: [
            .mode(Mode(scope: "meta", match: .string(#"\A#![^\r\n]*"#))),
            .mode(comment), .mode(heredoc), .mode(double), .mode(substitution), .mode(backtick),
            .mode(Mode(scope: "title.function", match: .string(#"\b[a-zA-Z_][\w-]*(?=\s*\(\s*\)\s*\{)"#)))
        ] + base)
    }

    private static func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }
}
