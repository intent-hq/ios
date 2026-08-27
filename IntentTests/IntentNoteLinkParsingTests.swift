import Foundation
import Testing

@testable import Intent

struct IntentNoteLinkParsingTests {
    private func parse(_ string: String) -> (workspaceId: String?, id: String)? {
        guard let url = URL(string: string) else { return nil }
        return NoteDetailView.parseIntentNoteLink(url)
    }

    private func parsedId(_ string: String) -> String? {
        parse(string)?.id
    }

    private func parsedWorkspaceId(_ string: String) -> String? {
        parse(string)?.workspaceId
    }

    // MARK: - Short forms

    @Test func shortFormNoteLinkParses() {
        #expect(parsedId("intent://local/note/abc-123") == "abc-123")
    }

    @Test func shortFormTaskLinkParses() {
        #expect(parsedId("intent://local/task/def-456") == "def-456")
    }

    @Test func shortFormCarriesNoWorkspaceId() {
        // Short forms have no embedded workspace: callers fall back to the
        // current workspace.
        #expect(parsedWorkspaceId("intent://local/note/abc-123") == nil)
        #expect(parsedWorkspaceId("intent://local/task/def-456") == nil)
    }

    // MARK: - Canonical workspace-qualified long forms

    @Test func longFormNoteLinkParses() {
        #expect(parsedId("intent://local/my-workspace/note/abc-123") == "abc-123")
    }

    @Test func longFormTaskLinkParses() {
        #expect(parsedId("intent://local/clicking-links/task/2b87bc19-86af") == "2b87bc19-86af")
    }

    @Test func longFormCarriesEmbeddedWorkspaceId() {
        // Long forms carry the embedded workspace ID so callers can route
        // cross-workspace links to the right workspace.
        #expect(parsedWorkspaceId("intent://local/my-workspace/note/abc-123") == "my-workspace")
        #expect(parsedWorkspaceId("intent://local/other-ws/task/2b87bc19-86af") == "other-ws")
    }

    @Test func shortFormReadingWinsWhenWorkspaceIdCollidesWithType() {
        // `note` in the first slot is the short form even when the next
        // segment is also a resource-type word.
        let link = parse("intent://local/note/task")
        #expect(link?.id == "task")
        #expect(link?.workspaceId == nil)
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

    // MARK: - Cross-workspace routing fallback

    @Test func callerFallbackUsesCurrentWorkspaceForShortForm() {
        // Mirrors the caller pattern: link.workspaceId ?? currentWorkspaceId.
        let currentWorkspaceId = "current-ws"
        let short = parse("intent://local/note/abc-123")
        #expect((short?.workspaceId ?? currentWorkspaceId) == "current-ws")
        let long = parse("intent://local/other-ws/note/abc-123")
        #expect((long?.workspaceId ?? currentWorkspaceId) == "other-ws")
    }
}
