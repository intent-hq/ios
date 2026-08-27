import Foundation
import Testing

@testable import Intent

struct IntentNoteLinkParsingTests {
    private func parse(_ string: String) -> String? {
        guard let url = URL(string: string) else { return nil }
        return NoteDetailView.parseIntentNoteLink(url)
    }

    // MARK: - Short forms

    @Test func shortFormNoteLinkParses() {
        #expect(parse("intent://local/note/abc-123") == "abc-123")
    }

    @Test func shortFormTaskLinkParses() {
        #expect(parse("intent://local/task/def-456") == "def-456")
    }

    // MARK: - Canonical workspace-qualified long forms

    @Test func longFormNoteLinkParses() {
        #expect(parse("intent://local/my-workspace/note/abc-123") == "abc-123")
    }

    @Test func longFormTaskLinkParses() {
        #expect(parse("intent://local/clicking-links/task/2b87bc19-86af") == "2b87bc19-86af")
    }

    @Test func shortFormReadingWinsWhenWorkspaceIdCollidesWithType() {
        // `note` in the first slot is the short form even when the next
        // segment is also a resource-type word.
        #expect(parse("intent://local/note/task") == "task")
    }

    // MARK: - Non-matching URLs

    @Test func httpsUrlIsRejected() {
        #expect(parse("https://example.com/note/abc") == nil)
    }

    @Test func nonLocalHostIsRejected() {
        #expect(parse("intent://remote/note/abc") == nil)
    }

    @Test func fileLinksAreRejected() {
        #expect(parse("intent://local/file/foo.png") == nil)
        #expect(parse("intent://local/ws-123/file/foo.png") == nil)
    }

    @Test func pairingUrlIsRejected() {
        #expect(parse("intent://pair?token=t&host=h&port=1") == nil)
    }

    @Test func missingIdIsRejected() {
        #expect(parse("intent://local/note") == nil)
        #expect(parse("intent://local/ws-123/note") == nil)
    }

    @Test func unknownResourceTypeIsRejected() {
        #expect(parse("intent://local/ws-123/comment/abc") == nil)
    }
}
