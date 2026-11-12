import Foundation
import Textual

/// Shared source preparation and semantic parsing only. Textual still resolves
/// attachments and applies the current session, style and layout on each view.
@MainActor
final class MarkdownContentCache: MarkupParser {
    static let shared = MarkdownContentCache()

    struct PreparedContent {
        let markdown: String
        let mermaidSources: [String: String]
        let pendingDiagram: MermaidMarkdownContent.PendingDiagram?

        init(_ source: String) {
            let mermaid = MermaidMarkdownContent(source)
            markdown = MarkdownTextView.replacingTaskListMarkers(mermaid.markdown)
            mermaidSources = mermaid.sources
            pendingDiagram = mermaid.pending.map { pending in
                .init(
                    markdown: MarkdownTextView.replacingTaskListMarkers(pending.markdown),
                    language: pending.language
                )
            }
        }

        var cost: Int {
            let pendingCost = pendingDiagram.map { $0.markdown.utf8.count + $0.language.utf8.count } ?? 0
            let sourcesCost = mermaidSources.reduce(0) { cost, source in
                cost + source.key.utf8.count + source.value.utf8.count + Self.sourceOverhead
            }
            return markdown.utf8.count + pendingCost + sourcesCost
        }

        private static let sourceOverhead = 128
    }

    // Bump these when preparation or parser semantics change. This parser has ONE
    // fixed configuration: Foundation defaults, nil base URL, no syntax extensions.
    // Future options must get distinct keys before sharing this semantic store.
    private static let preparationVersion = 1
    private static let parserVersion = 1
    /// Offsets the chat variant's key so it never shares an entry with plain parses.
    private static let standaloneLinkRowsVariant = 1 << 16
    private static let preparedCostLimit = 2_097_152
    private static let parsedCostLimit = 8_388_608
    private static let preparedEntryLimit = 128
    private static let parsedEntryLimit = 256
    private static let semanticSourceMultiplier = 8
    private static let semanticRunOverhead = 256

    private let prepared: BoundedMarkdownCache<PreparedContent>
    private let parsed: BoundedMarkdownCache<AttributedString>
    private let parser = AttributedStringMarkdownParser.markdown()

    var preparedEntryCount: Int { prepared.count }
    var parsedEntryCount: Int { parsed.count }
    var totalCost: Int { prepared.totalCost + parsed.totalCost }

    init() {
        prepared = BoundedMarkdownCache(
            maximumEntries: Self.preparedEntryLimit,
            maximumCost: Self.preparedCostLimit,
            traceName: "MarkdownPreparation"
        )
        parsed = BoundedMarkdownCache(
            maximumEntries: Self.parsedEntryLimit,
            maximumCost: Self.parsedCostLimit,
            traceName: "MarkdownParse"
        )
    }

    func preparedContent(for source: String) -> PreparedContent {
        prepared.value(
            for: source,
            version: Self.preparationVersion,
            cost: { $0.cost },
            create: { PreparedContent(source) }
        )
    }

    func attributedString(for input: String) throws -> AttributedString {
        try parsed.value(
            for: input,
            version: Self.parserVersion,
            cost: { Self.parsedCost(input: input, value: $0) },
            create: { try parser.attributedString(for: input) }
        )
    }

    /// The parse with each single-link paragraph rewritten into a
    /// `StandaloneLinkRow` block, cached separately from the plain parse.
    func attributedStringWithLinkRows(for input: String) throws -> AttributedString {
        let plain = try attributedString(for: input)
        return parsed.value(
            for: input,
            version: Self.parserVersion + Self.standaloneLinkRowsVariant,
            cost: { Self.parsedCost(input: input, value: $0) },
            create: { StandaloneLinkRow.rewriting(plain) }
        )
    }

    /// Foundation's storage size is opaque. Charge conservatively for source,
    /// attributed characters and semantic runs; this is not a heap-size claim.
    private static func parsedCost(input: String, value: AttributedString) -> Int {
        input.utf8.count * semanticSourceMultiplier
            + String(value.characters).utf8.count * 2
            + value.runs.count * semanticRunOverhead
    }

    /// Chat's parser: standalone link lines become full-width rows.
    struct LinkRowsParser: MarkupParser {
        func attributedString(for input: String) throws -> AttributedString {
            try MarkdownContentCache.shared.attributedStringWithLinkRows(for: input)
        }
    }
}
