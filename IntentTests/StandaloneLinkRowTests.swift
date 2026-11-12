import Foundation
import Testing

@testable import Intent

/// Chat draws a paragraph that is only one link as a full-width row. These
/// cover which paragraphs qualify and that the rewrite keeps list context.
@MainActor
struct StandaloneLinkRowTests {
    private func rows(in markdown: String) throws -> [StandaloneLinkRow] {
        let parsed = try MarkdownContentCache().attributedStringWithLinkRows(for: markdown)
        return parsed.runs[\.presentationIntent].compactMap { intent, _ in
            guard case .codeBlock(let hint) = intent?.components.first?.kind else { return nil }
            return StandaloneLinkRow(languageHint: hint)
        }
    }

    @Test func standaloneLinkParagraphsAndListItemsBecomeRows() throws {
        let markdown = """
        Here are the notes.

        [Open the report](reports/Demo%20report.html)

        - [Open the text notes](intent://local/file/docs/Demo%20notes.txt)
        - [Open the preview](http://localhost:3000)
        """
        #expect(try rows(in: markdown) == [
            StandaloneLinkRow(title: "Open the report", url: try #require(URL(string: "reports/Demo%20report.html"))),
            StandaloneLinkRow(
                title: "Open the text notes",
                url: try #require(URL(string: "intent://local/file/docs/Demo%20notes.txt"))
            ),
            StandaloneLinkRow(title: "Open the preview", url: try #require(URL(string: "http://localhost:3000")))
        ])
    }

    @Test(arguments: [
        "Read [the report](https://example.com) first.",
        "[One](https://example.com/1) [Two](https://example.com/2)",
        "[![Chart](intent://local/file/chart.png)](https://example.com)",
        "```\n[Not a link](https://example.com)\n```",
        "Plain text only."
    ])
    func paragraphsWithOtherContentStayInline(markdown: String) throws {
        #expect(try rows(in: markdown).isEmpty)
    }

    @Test func listItemRowKeepsItsListAndIdentity() throws {
        let source = "- [Open](https://example.com)\n- plain"
        let cache = MarkdownContentCache()
        let plain = try cache.attributedString(for: source)
        let rewritten = try cache.attributedStringWithLinkRows(for: source)
        let before = try #require(plain.runs[\.presentationIntent].first?.0)
        let after = try #require(rewritten.runs[\.presentationIntent].first?.0)
        #expect(after.components.map(\.identity) == before.components.map(\.identity))
        #expect(after.components.dropFirst().map(\.kind) == before.components.dropFirst().map(\.kind))
        #expect(String(rewritten.characters) == String(plain.characters))
        // The plain parse is cached unchanged for notes and pull requests.
        #expect(try cache.attributedString(for: source) == plain)
    }

    @Test func languageHintRoundTripsAndRejectsParsedHints() throws {
        let row = StandaloneLinkRow(title: "Open the report", url: try #require(URL(string: "reports/a%20b.html")))
        #expect(StandaloneLinkRow(languageHint: row.languageHint) == row)
        #expect(StandaloneLinkRow(languageHint: "intent-link-row") == nil)
        #expect(StandaloneLinkRow(languageHint: "swift") == nil)
        #expect(StandaloneLinkRow(languageHint: nil) == nil)
    }

    @Test(arguments: [
        ("reports/Demo%20report.html", true),
        ("intent://local/file/docs/notes.txt", true),
        ("intent://local/settings", false),
        ("https://example.com/file/a", false)
    ])
    func fileLinksGetTheFileIcon(link: String, opensFile: Bool) throws {
        let row = StandaloneLinkRow(title: "Open", url: try #require(URL(string: link)))
        #expect(row.opensFile == opensFile)
    }
}
