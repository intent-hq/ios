import SwiftHighlight

/// Adapted from highlight.js 11.11.1 css (BSD-3-Clause; see Acknowledgements).
/// Plain CSS, including custom properties and nested selectors.
nonisolated enum WorkspaceStylesheetLanguage {
    static func css(_: Highlight) -> Language {
        let strings: [ModeReference] = ["'", "\""].map { quote in
            .mode(Mode(scope: "string", begin: .string(quote), end: .string(quote), contains: [.mode(Highlight.backslashEscape)]))
        }
        let variable = Mode(scope: "variable", match: .string(#"--[a-zA-Z_][\w-]*"#))
        let number = Mode(scope: "number", match: .string(#"[+-]?(?:\b[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[a-zA-Z]+|%)?"#))
        let values: [ModeReference] = strings + [
            .mode(Highlight.cBlockCommentMode), .mode(variable), .mode(number),
            .mode(Mode(scope: "number", match: .string(#"#[0-9a-fA-F]{3,8}\b"#))),
            .mode(Mode(scope: "meta", match: .string(#"!important\b"#))),
            .mode(Mode(scope: "built_in", match: .string(#"[a-zA-Z-]+(?=\()"#))),
            .mode(Mode(scope: "literal", match: .string(#"\b(?:none|auto|inherit|initial|unset|revert|solid|flex|grid|block|inline|relative|absolute|fixed|transparent|currentColor)\b"#)))
        ]
        let selectors: [ModeReference] = [
            .mode(Mode(scope: "keyword", match: .string(#"@[\w-]+"#))),
            .mode(Mode(scope: "selector-id", match: .string(#"#[\w-]+"#))),
            .mode(Mode(scope: "selector-class", match: .string(#"\.[a-zA-Z_-][\w-]*"#))),
            .mode(Mode(scope: "selector-pseudo", match: .string(#"::?[a-zA-Z-]+"#))),
            .mode(Mode(scope: "selector-attr", begin: .string(#"\["#), end: .string(#"\]"#), contains: strings))
        ]
        let property = Mode(
            begin: .string(#"([a-zA-Z_-][\w-]*)(\s*:)"#),
            end: .string(#"(?=[;{}])"#),
            contains: values,
            beginScope: .indexed([1: "attribute"])
        )
        let customProperty = Mode(
            begin: .string(#"(--[\w-]+)(\s*:)"#),
            end: .string(#"(?=[;{}])"#),
            contains: values,
            beginScope: .indexed([1: "variable"])
        )
        let comments: [ModeReference] = [.mode(Highlight.cBlockCommentMode)]
        let block = Mode(
            begin: .string(#"\{"#),
            end: .string(#"\}"#),
            contains: [.self] + comments + [.mode(customProperty)] + selectors + [.mode(property)] + values
        )
        return Language(name: "CSS", caseInsensitive: true, contains: comments + [.mode(variable)] + selectors + [
            .mode(block), .mode(number), .mode(Mode(scope: "selector-tag", match: .string(#"\b[a-zA-Z][\w-]*\b"#)))
        ] + strings)
    }
}
