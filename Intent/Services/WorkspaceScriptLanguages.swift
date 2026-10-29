import SwiftHighlight

/// Adapted from highlight.js 11.11.1 javascript/typescript and lib/ecmascript
/// (BSD-3-Clause, Ivan Sagalaev and contributors; see Acknowledgements).
/// JSX/TSX retain JS/TS tokens; embedded markup is deliberately not parsed.
nonisolated enum WorkspaceScriptLanguages {
    static func javascript(_: Highlight) -> Language { language(typescript: false) }
    static func typescript(_: Highlight) -> Language { language(typescript: true) }

    private static let identifier = #"[A-Za-z$_][0-9A-Za-z$_]*"#
    private static let reserved = """
        as in of if for while finally var new function do return void else break catch instanceof
        with throw case default try switch continue typeof delete let yield const class debugger
        async await static import from export extends using
        """
    private static let typeKeywords = "type interface public private protected implements declare abstract readonly enum override satisfies namespace keyof infer is asserts out"
    private static let builtIns = """
        Object Function Boolean Symbol Math Date Number BigInt String RegExp Array Float32Array Float64Array
        Int8Array Uint8Array Uint8ClampedArray Int16Array Int32Array Uint16Array Uint32Array BigInt64Array BigUint64Array
        Set Map WeakSet WeakMap ArrayBuffer SharedArrayBuffer Atomics DataView JSON Promise Generator GeneratorFunction
        AsyncFunction Reflect Proxy Intl WebAssembly Error EvalError InternalError RangeError ReferenceError SyntaxError
        TypeError URIError setInterval setTimeout clearInterval clearTimeout require exports eval isFinite isNaN
        parseFloat parseInt decodeURI decodeURIComponent encodeURI encodeURIComponent escape unescape
        """

    private static func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

    private static func language(typescript: Bool) -> Language {
        let keywords = HLJS.kw(
            pattern: .string(identifier),
            keyword: words(reserved + (typescript ? " " + typeKeywords : "")),
            literal: words("true false null undefined NaN Infinity"),
            builtIn: words(builtIns),
            type: typescript ? words("any void number boolean string object never symbol bigint unknown") : [],
            custom: ["variable.language": words("arguments this super console window document localStorage sessionStorage module global")]
        )
        let declarations = Mode(
            match: .string(#"\b(class|extends|interface|type|enum|namespace)(\s+)(\#(identifier))"#),
            beginScope: .indexed([1: "keyword", declarationNameCapture: "title.class"])
        )
        let function = Mode(
            match: .string(#"\b(function)(\s*\*?\s+)(\#(identifier))"#),
            beginScope: .indexed([1: "keyword", declarationNameCapture: "title.function"])
        )
        let typeReference = Mode(scope: "title.class", match: .string(#"\b[A-Z][A-Za-z0-9_$]*\b"#), keywords: keywords)
        let decoration = Mode(scope: "meta", match: .string("@" + identifier + #"(?:\.\#(identifier))*"#))
        let property = Mode(scope: "attr", match: .string(identifier + #"(?=\s*\??:)"#))
        let functionCall = Mode(
            scope: "title.function",
            match: .string(#"\b(?!if\b|for\b|while\b|switch\b|catch\b|import\b|super\b)\#(identifier)(?=\s*\()"#),
            keywords: keywords
        )
        return Language(
            name: typescript ? "TypeScript" : "JavaScript",
            keywords: keywords,
            contains: [.mode(Mode(scope: "meta", match: .string(#"\A#![^\r\n]*"#)))]
                + expressions(keywords: keywords, templateDepth: 0)
                + [.mode(declarations), .mode(function), .mode(decoration), .mode(property), .mode(functionCall), .mode(typeReference)]
        )
    }

    private static let number = Mode(
        scope: "number",
        match: .string(#"\b0[xX][0-9a-fA-F_]+n?\b|\b0[bB][01_]+n?\b|\b0[oO][0-7_]+n?\b|(?:\b[0-9][0-9_]*(?:\.[0-9_]*)?|\.[0-9][0-9_]*)(?:[eE][+-]?[0-9_]+)?n?"#)
    )
    private static let strings: [ModeReference] = ["'", "\""].map { quote in
        .mode(Mode(scope: "string", begin: .string(quote), end: .string(quote + #"|(?=\r?$)"#), contains: [.mode(Highlight.backslashEscape)]))
    }
    private static let comments: [ModeReference] = [
        .mode(Mode(scope: "comment", begin: .string(#"/\*\*"#), end: .string(#"\*/"#), contains: [
            .mode(Mode(scope: "doctag", match: .string(#"@[A-Za-z]+"#))),
            .mode(Mode(scope: "type", begin: .string(#"\{"#), end: .string(#"\}"#)))
        ])),
        .mode(Highlight.cBlockCommentMode), .mode(Highlight.cLineCommentMode)
    ]

    private static func expressions(keywords: Keywords, templateDepth: Int) -> [ModeReference] {
        var modes = comments + strings + [.mode(number), .mode(regexValue)]
        // Mode values cannot mutually refer to one another. Bound nested templates
        // rather than building a cyclic grammar; braces themselves recurse via .self.
        let nested = templateDepth < maxTemplateDepth ? expressions(keywords: keywords, templateDepth: templateDepth + 1) : modes
        let braces = Mode(begin: .string(#"\{"#), end: .string(#"\}"#), keywords: keywords, contains: [.self] + nested)
        let substitution = Mode(
            scope: "subst",
            begin: .string(#"\$\{"#),
            end: .string(#"\}"#),
            keywords: keywords,
            contains: nested + [.mode(braces)]
        )
        modes.append(.mode(Mode(
            scope: "string",
            begin: .string("`"),
            end: .string("`"),
            contains: [.mode(Highlight.backslashEscape), .mode(substitution)]
        )))
        return modes
    }

    private static let maxTemplateDepth = 3
    private static let declarationNameCapture = 3

    // Like upstream's value container, only admit regex after expression starters;
    // a / b / c must remain division. No unbounded whole-line lookahead/backtracking.
    private static let regexValue = Mode(
        begin: .string(#"(?:\b(?:return|throw|case)\b|[=(:,!&|?;\[{])\s*(?=/(?![*/]))"#),
        keywords: HLJS.kw(keyword: ["return", "throw", "case"]),
        contains: comments + [
            .mode(Mode(
                scope: "regexp",
                begin: .string(#"/(?![*/])"#),
                end: .string(#"/[dgimsuvy]*|(?=\r?$)"#),
                contains: [
                    .mode(Highlight.backslashEscape),
                    .mode(Mode(begin: .string(#"\["#), end: .string(#"\]|(?=\r?$)"#), contains: [.mode(Highlight.backslashEscape)]))
                ],
                endsParent: true
            ))
        ]
    )
}
