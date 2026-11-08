import Foundation
@testable import Intent
import Testing

struct SlashSkillContextTests {
    @Test(arguments: ["/", "/review", "Please /review", "Next\n/review", "👩🏽‍💻 /review"])
    func detectsTokenAtCaret(text: String) throws {
        let context = try #require(SlashSkillContext.find(in: text, selection: NSRange(location: text.utf16.count, length: 0)))
        #expect(context.query == (text == "/" ? "" : "review"))
        let range = try #require(Range(context.range, in: text))
        #expect(text[range] == "/" + context.query)
    }

    @Test(arguments: ["https://example.com/review", "src/review", "/usr/bin", "//server", "word/review", "/review ", "/review\n", "hello"])
    func ignoresPathsURLsAndCompletedTokens(text: String) {
        #expect(SlashSkillContext.find(in: text, selection: NSRange(location: text.utf16.count, length: 0)) == nil)
    }

    @Test func handlesMiddleOfTokenAndRejectsSelectionsAndInvalidUTF16Offsets() throws {
        let text = "👋 /release-notes then continue"
        let caret = "👋 /rel".utf16.count
        let context = try #require(SlashSkillContext.find(in: text, selection: NSRange(location: caret, length: 0)))
        #expect(context.query == "rel")
        let range = try #require(Range(context.range, in: text))
        #expect(text[range] == "/release-notes")
        #expect(SlashSkillContext.find(in: text, selection: NSRange(location: caret, length: 2)) == nil)
        #expect(SlashSkillContext.find(in: text, selection: NSRange(location: 1, length: 0)) == nil)
        #expect(SlashSkillContext.find(in: text, selection: NSRange(location: text.utf16.count + 1, length: 0)) == nil)
    }

    @Test func ranksNameMatchesBeforeDescriptionsCaseInsensitively() {
        let skills = [
            skill("notes", description: "Prepare a release"), skill("pre-release"),
            skill("release-notes"), skill("RELEASE"), skill("unrelated")
        ]
        #expect(SlashSkillContext.ranked(skills, query: "reLEAse").map(\.name) == ["RELEASE", "release-notes", "pre-release", "notes"])
        #expect(SlashSkillContext.ranked(skills, query: "missing").isEmpty)
        #expect(SlashSkillContext.ranked(skills, query: "").count == skills.count)
    }

    private func skill(_ name: String, description: String = "") -> SkillInfo {
        SkillInfo(name: name, description: description, location: "/\(name)/SKILL.md", scope: "user")
    }
}
