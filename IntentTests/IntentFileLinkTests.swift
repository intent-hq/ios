import Foundation
import Testing
@testable import Intent

struct IntentFileLinkTests {
    private func parse(_ string: String) -> IntentFileLink? {
        guard let url = URL(string: string) else { return nil }
        return IntentFileLink.parse(url)
    }

    // MARK: - parse: accepted forms

    @Test func shortFormParsesPathWithoutWorkspace() {
        let link = parse("intent://local/file/foo.png")
        #expect(link == IntentFileLink(workspaceId: nil, path: "foo.png"))
    }

    @Test func shortFormKeepsNestedPathSegments() {
        let link = parse("intent://local/file/a/b/c.gif")
        #expect(link == IntentFileLink(workspaceId: nil, path: "a/b/c.gif"))
    }

    @Test func longFormExtractsWorkspaceId() {
        let link = parse("intent://local/ws-123/file/sub/dir/foo.png")
        #expect(link == IntentFileLink(workspaceId: "ws-123", path: "sub/dir/foo.png"))
    }

    @Test func percentEncodedSegmentsAreDecoded() {
        let link = parse("intent://local/file/my%20dir/pic%20name.png")
        #expect(link == IntentFileLink(workspaceId: nil, path: "my dir/pic name.png"))
    }

    @Test func leadingFileSegmentWinsOverWorkspaceReading() {
        // `file` in the first slot is the short form even when the path's own
        // first segment is also named `file`.
        let link = parse("intent://local/file/file/foo.png")
        #expect(link == IntentFileLink(workspaceId: nil, path: "file/foo.png"))
    }

    // MARK: - parse: rejected forms

    @Test func noteAndTaskLinksAreNotFileLinks() {
        #expect(parse("intent://local/note/abc-123") == nil)
        #expect(parse("intent://local/task/abc-123") == nil)
        #expect(parse("intent://local/ws-1/note/abc-123") == nil)
    }

    @Test func wrongHostOrSchemeIsRejected() {
        #expect(parse("intent://remote/file/foo.png") == nil)
        #expect(parse("intent://pair?token=t&host=h&port=1") == nil)
        #expect(parse("https://local/file/foo.png") == nil)
    }

    @Test func missingPathIsRejected() {
        #expect(parse("intent://local/file") == nil)
        #expect(parse("intent://local/ws-1/file") == nil)
        #expect(parse("intent://local") == nil)
    }

    // MARK: - parse: traversal-shaped paths (desktop parser parity)

    @Test func dotDotAndDotSegmentsAreRejected() {
        #expect(parse("intent://local/file/../secret.png") == nil)
        #expect(parse("intent://local/file/a/../b.png") == nil)
        #expect(parse("intent://local/file/./a.png") == nil)
        #expect(parse("intent://local/ws-1/file/../a.png") == nil)
    }

    @Test func percentEncodedTraversalIsRejected() {
        // %2E%2E = "..", %2F = "/" smuggled into one segment.
        #expect(parse("intent://local/file/%2E%2E/secret.png") == nil)
        #expect(parse("intent://local/file/..%2Fsecret.png") == nil)
        #expect(parse("intent://local/file/a%2F..%2Fb.png") == nil)
    }

    @Test func emptySegmentsFromDoubledSlashesAreRejected() {
        #expect(parse("intent://local/file//etc/passwd.png") == nil)
        #expect(parse("intent://local/file/a//b.png") == nil)
        #expect(parse("intent://local/file/a.png/") == nil)
    }

    @Test func backslashSegmentsAreRejected() {
        #expect(parse("intent://local/file/a%5Cb.png") == nil)
    }

    // MARK: - isImage allowlist

    @Test func allowlistedImageExtensionsAreImages() {
        for ext in ["png", "jpg", "jpeg", "gif", "webp"] {
            #expect(parse("intent://local/file/pic.\(ext)")?.isImage == true)
        }
    }

    @Test func extensionMatchingIsCaseInsensitive() {
        #expect(parse("intent://local/file/pic.PNG")?.isImage == true)
        #expect(parse("intent://local/file/pic.JpEg")?.isImage == true)
    }

    @Test func nonImageExtensionsAreNotImages() {
        for ext in ["svg", "txt", "mp4", "pdf"] {
            #expect(parse("intent://local/file/doc.\(ext)")?.isImage == false)
        }
        #expect(parse("intent://local/file/no-extension")?.isImage == false)
    }
}
