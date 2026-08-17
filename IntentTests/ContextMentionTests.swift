import Foundation
import Testing
@testable import Intent

struct ContextMentionTests {
    private func base64(_ json: String) -> String {
        Data(json.utf8).base64EncodedString()
    }

    // MARK: - Base64 JSON payloads

    @Test func base64JSONTokenWithUrl() {
        let token = base64(
            #"{"provider":"linear","identifier":"AU-123","title":"Fix crash","url":"https://linear.app/i/AU-123"}"#
        )
        let segments = ContextMention.segments(from: "@context[\(token)]")
        #expect(segments == [.mention(ContextMention(
            provider: "linear", identifier: "AU-123", title: "Fix crash",
            url: "https://linear.app/i/AU-123"
        ))])
    }

    @Test func base64JSONTokenWithoutUrl() {
        let token = base64(##"{"provider":"github","identifier":"#42","title":"Bug","url":""}"##)
        let segments = ContextMention.segments(from: "@context[\(token)]")
        #expect(segments == [.mention(ContextMention(
            provider: "github", identifier: "#42", title: "Bug", url: nil
        ))])
    }

    @Test func base64JSONTitleFallsBackToIdentifierThenSharedContext() {
        let noTitle = base64(#"{"provider":"linear","identifier":"AU-9","title":""}"#)
        guard case .mention(let m1) = ContextMention.segments(from: "@context[\(noTitle)]")[0] else {
            Issue.record("expected mention"); return
        }
        #expect(m1.title == "AU-9")

        let empty = base64(#"{"provider":"","identifier":"","title":""}"#)
        guard case .mention(let m2) = ContextMention.segments(from: "@context[\(empty)]")[0] else {
            Issue.record("expected mention"); return
        }
        #expect(m2.title == "Shared context")
        #expect(m2.provider == "browser")
    }

    // MARK: - Pipe-separated payloads

    @Test func pipeSeparatedToken() {
        let segments = ContextMention.segments(from: "@context[linear|AU-123|Fix crash]")
        #expect(segments == [.mention(ContextMention(
            provider: "linear", identifier: "AU-123", title: "Fix crash", url: nil
        ))])
    }

    @Test func pipeSeparatedTitleFallsBackToIdentifier() {
        guard case .mention(let m) = ContextMention.segments(from: "@context[github|#7]")[0] else {
            Issue.record("expected mention"); return
        }
        #expect(m.provider == "github")
        #expect(m.identifier == "#7")
        #expect(m.title == "#7")
    }

    // MARK: - Malformed base64/JSON fallback

    @Test func malformedBase64FallsBackToPipeParsing() {
        // Starts with eyJ but is not valid base64.
        let segments = ContextMention.segments(from: "@context[eyJ%%%not-base64]")
        #expect(segments == [.mention(ContextMention(
            provider: "eyJ%%%not-base64", identifier: "", title: "", url: nil
        ))])
    }

    @Test func base64OfInvalidJSONFallsBackToPipeParsing() {
        let token = base64(#"{"broken"#) // valid base64, starts with eyJ, invalid JSON
        guard case .mention(let m) = ContextMention.segments(from: "@context[\(token)]")[0] else {
            Issue.record("expected mention"); return
        }
        #expect(m.provider == token)
        #expect(m.identifier == "")
    }

    // MARK: - Interleaving

    @Test func tokenEmbeddedMidText() {
        let segments = ContextMention.segments(from: "look at @context[linear|AU-1|One] please")
        #expect(segments.count == 3)
        #expect(segments[0] == .text("look at "))
        #expect(segments[1] == .mention(ContextMention(
            provider: "linear", identifier: "AU-1", title: "One", url: nil
        )))
        #expect(segments[2] == .text(" please"))
    }

    @Test func textWithNoTokensIsSingleTextSegment() {
        let text = "no mentions here, not even @context without brackets"
        #expect(ContextMention.segments(from: text) == [.text(text)])
    }

    @Test func emptyTextYieldsNoSegments() {
        #expect(ContextMention.segments(from: "") == [])
    }

    @Test func multipleTokens() {
        let segments = ContextMention.segments(
            from: "@context[linear|AU-1|One] and @context[github|#2|Two]"
        )
        #expect(segments.count == 3)
        #expect(segments[0] == .mention(ContextMention(
            provider: "linear", identifier: "AU-1", title: "One", url: nil
        )))
        #expect(segments[1] == .text(" and "))
        #expect(segments[2] == .mention(ContextMention(
            provider: "github", identifier: "#2", title: "Two", url: nil
        )))
    }

    // MARK: - Clipboard/plain-text transformation

    @Test func replacingTokensWithTitlesDecodesBase64Token() {
        let token = base64(
            #"{"provider":"linear","identifier":"AU-123","title":"Fix crash","url":"https://linear.app/i/AU-123"}"#
        )
        let result = ContextMention.replacingTokensWithTitles(
            in: "look at @context[\(token)] please"
        )
        #expect(result == "look at Fix crash please")
    }

    @Test func replacingTokensWithTitlesHandlesMultipleTokens() {
        let result = ContextMention.replacingTokensWithTitles(
            in: "@context[linear|AU-1|One] and @context[github|#2|Two]"
        )
        #expect(result == "One and Two")
    }

    @Test func replacingTokensWithTitlesLeavesPlainTextUnchanged() {
        let text = "no mentions here, not even @context without brackets"
        #expect(ContextMention.replacingTokensWithTitles(in: text) == text)
    }

    // MARK: - User text rows (MessageView display transformation)

    @Test func userTextRowsSplitsTextAroundChip() {
        let rows = MessageView.userTextRows("look at @context[linear|AU-1|One] please")
        #expect(rows == [
            .text("look at"),
            .chips([ContextMention(provider: "linear", identifier: "AU-1", title: "One", url: nil)]),
            .text("please"),
        ])
    }

    @Test func userTextRowsCollapsesConsecutiveMentionsIntoOneChipRow() {
        let rows = MessageView.userTextRows(
            "@context[linear|AU-1|One] @context[github|#2|Two]\nintro text"
        )
        #expect(rows == [
            .chips([
                ContextMention(provider: "linear", identifier: "AU-1", title: "One", url: nil),
                ContextMention(provider: "github", identifier: "#2", title: "Two", url: nil),
            ]),
            .text("intro text"),
        ])
    }

    @Test func userTextRowsWithoutTokensIsSingleTextRow() {
        let text = "plain message"
        #expect(MessageView.userTextRows(text) == [.text(text)])
    }

    // MARK: - Chip presentation

    @Test func chipDisplayTitleTruncatesLongTitles() {
        let long = String(repeating: "a", count: 40)
        let truncated = ContextMentionChipView.displayTitle(long)
        #expect(truncated == String(repeating: "a", count: 30) + "…")
        #expect(ContextMentionChipView.displayTitle("short") == "short")
    }

    @Test func chipIconNamesFollowProviderMapping() {
        #expect(ContextMentionChipView.iconName(for: "github") == "arrow.triangle.pull")
        #expect(ContextMentionChipView.iconName(for: "linear") == "ticket")
        #expect(ContextMentionChipView.iconName(for: "sentry") == "ladybug")
        #expect(ContextMentionChipView.iconName(for: "browser") == "link")
        #expect(ContextMentionChipView.iconName(for: "external") == "link")
    }
}
