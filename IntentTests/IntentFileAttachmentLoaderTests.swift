import Foundation
import Testing
import Textual
import UIKit
@testable import Intent

/// Covers markdown-image URL routing (which URLs the loader claims) and the
/// remote-image attachment path, including tap routing into the lightbox.
@MainActor
struct IntentFileAttachmentLoaderTests {
    // MARK: - URL routing

    private func route(_ string: String) -> MarkdownImageRoute {
        MarkdownImageRoute.route(for: URL(string: string)!)
    }

    @Test func httpsURLRoutesToRemote() {
        #expect(route("https://example.com/pic.png") == .remote)
    }

    @Test func httpURLRoutesToRemote() {
        #expect(route("http://example.com/pic.png") == .remote)
    }

    @Test func uppercaseSchemeRoutesToRemote() {
        #expect(route("HTTPS://example.com/pic.png") == .remote)
    }

    @Test func remoteURLWithoutImageExtensionRoutesToRemote() {
        #expect(route("https://example.com/image?id=4") == .remote)
    }

    @Test func intentFileLinkRoutesToIntentFile() {
        #expect(
            route("intent://local/file/pic.png")
                == .intentFile(IntentFileLink(workspaceId: nil, path: "pic.png")))
    }

    @Test func longFormIntentFileLinkRoutesToIntentFile() {
        #expect(
            route("intent://local/ws-1/file/a/b.png")
                == .intentFile(IntentFileLink(workspaceId: "ws-1", path: "a/b.png")))
    }

    @Test func intentNoteLinkRoutesToFallback() {
        #expect(route("intent://local/note/spec") == .fallback)
    }

    @Test func otherSchemesRouteToFallback() {
        #expect(route("ftp://example.com/pic.png") == .fallback)
        #expect(route("data:image/png;base64,AAAA") == .fallback)
    }

    @Test func schemelessRelativeURLRoutesToFallback() {
        #expect(route("images/pic.png") == .fallback)
    }

    // MARK: - Remote attachment path

    private static let remoteURL = URL(string: "https://example.com/pic.png")!

    @Test func loadedRemoteImageYieldsLightboxCapableAttachment() async {
        let image = UIImage()
        let loader = IntentFileAttachmentLoader(
            workspaceId: nil, fallback: .image(), remoteImage: { _ in image })

        let attachment = await loader.remoteImageAttachment(for: Self.remoteURL, text: "alt")

        let base = attachment?.base as? IntentFileImageAttachment
        #expect(base?.image === image)
        #expect(base?.altText == "alt")
    }

    @Test func tappedRemoteImageAttachmentRoutesToLightbox() async {
        let image = UIImage()
        let loader = IntentFileAttachmentLoader(
            workspaceId: nil, fallback: .image(), remoteImage: { _ in image })

        guard let attachment = await loader.remoteImageAttachment(for: Self.remoteURL, text: "alt")
        else {
            Issue.record("expected a remote image attachment")
            return
        }

        #expect(MarkdownTextView.lightboxImage(for: attachment) === image)
    }

    @Test func remoteFetchFailureFallsThroughToFallback() async {
        struct FetchFailure: Error {}
        let loader = IntentFileAttachmentLoader(
            workspaceId: nil, fallback: .image(), remoteImage: { _ in throw FetchFailure() })

        let attachment = await loader.remoteImageAttachment(for: Self.remoteURL, text: "alt")

        #expect(attachment == nil)
    }
}
