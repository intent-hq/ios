import Foundation
@testable import Intent
import Testing
import Textual
import UIKit

/// Covers markdown-image URL routing (which URLs the loader claims) and the
/// remote-image attachment path, including tap routing into the lightbox.
@MainActor
struct IntentFileAttachmentLoaderTests {
    // MARK: - URL routing

    private func route(_ string: String) -> MarkdownImageRoute {
        guard let url = URL(string: string) else {
            Issue.record("Expected a valid fixture URL: \(string)")
            return .fallback
        }
        return MarkdownImageRoute.route(for: url)
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
                == .intentFile(IntentFileLink(workspaceId: nil, path: "pic.png"))
        )
    }

    @Test func longFormIntentFileLinkRoutesToIntentFile() {
        #expect(
            route("intent://local/ws-1/file/a/b.png")
                == .intentFile(IntentFileLink(workspaceId: "ws-1", path: "a/b.png"))
        )
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

    // MARK: - Intent-file fetcher injection

    @MainActor private final class FileImageFetchLog {
        var entries: [(workspaceId: String, path: String)] = []

        func record(_ workspaceId: String, _ path: String) {
            entries.append((workspaceId, path))
        }
    }

    @Test func intentFileLinkUsesInjectedFileImageFetcher() async throws {
        let image = UIImage()
        let log = FileImageFetchLog()
        var loader = IntentFileAttachmentLoader(workspaceId: "ws-1", fallback: .image())
        loader.fileImage = { workspaceId, path in
            await log.record(workspaceId, path)
            return image
        }

        let attachment = try await loader.resolvedAttachment(
            for: URL(string: "intent://local/file/pic.png")!,
            text: "alt"
        ) {
            Issue.record("intent-file links must not consult the fallback loader")
            return AnyAttachment(IntentFileFailureAttachment(altText: "from-fallback"))
        }

        #expect(log.entries.count == 1)
        #expect(log.entries.first?.workspaceId == "ws-1")
        #expect(log.entries.first?.path == "pic.png")
        #expect((attachment.base as? IntentFileImageAttachment)?.image === image)
    }

    // MARK: - Remote attachment path

    private static let remoteURL = URL(string: "https://example.com/pic.png")!

    @Test func loadedRemoteImageYieldsLightboxCapableAttachment() async {
        let image = UIImage()
        let loader = IntentFileAttachmentLoader(
            workspaceId: nil,
            fallback: .image()
        ) { _ in image }

        let attachment = await loader.remoteImageAttachment(for: Self.remoteURL, text: "alt")

        let base = attachment?.base as? IntentFileImageAttachment
        #expect(base?.image === image)
        #expect(base?.altText == "alt")
    }

    @Test func tappedRemoteImageAttachmentRoutesToLightbox() async {
        let image = UIImage()
        let loader = IntentFileAttachmentLoader(
            workspaceId: nil,
            fallback: .image()
        ) { _ in image }

        guard let attachment = await loader.remoteImageAttachment(for: Self.remoteURL, text: "alt")
        else {
            Issue.record("expected a remote image attachment")
            return
        }

        #expect(MarkdownTextView.lightboxImage(for: attachment) === image)
    }

    @Test func remoteFetchFailureDelegatesToFallbackLoader() async throws {
        struct FetchFailure: Error {}
        let loader = IntentFileAttachmentLoader(
            workspaceId: nil,
            fallback: .image()
        ) { _ in throw FetchFailure() }
        var fallbackCalls = 0

        let attachment = try await loader.resolvedAttachment(for: Self.remoteURL, text: "alt") {
            fallbackCalls += 1
            return AnyAttachment(IntentFileFailureAttachment(altText: "from-fallback"))
        }

        #expect(fallbackCalls == 1)
        #expect((attachment.base as? IntentFileFailureAttachment)?.altText == "from-fallback")
    }

    @Test func loadedRemoteImageDoesNotInvokeFallbackLoader() async throws {
        let image = UIImage()
        let loader = IntentFileAttachmentLoader(
            workspaceId: nil,
            fallback: .image()
        ) { _ in image }
        var fallbackCalls = 0

        let attachment = try await loader.resolvedAttachment(for: Self.remoteURL, text: "alt") {
            fallbackCalls += 1
            return AnyAttachment(IntentFileFailureAttachment(altText: "from-fallback"))
        }

        #expect(fallbackCalls == 0)
        #expect((attachment.base as? IntentFileImageAttachment)?.image === image)
    }

    @Test func nonImageURLDelegatesToFallbackLoader() async throws {
        let loader = IntentFileAttachmentLoader(
            workspaceId: nil,
            fallback: .image()
        ) { _ in
            Issue.record("remote loader must not be consulted for non-http(s) URLs")
            return UIImage()
        }
        var fallbackCalls = 0

        let attachment = try await loader.resolvedAttachment(
            for: URL(string: "intent://local/note/spec")!,
            text: "alt"
        ) {
            fallbackCalls += 1
            return AnyAttachment(IntentFileFailureAttachment(altText: "from-fallback"))
        }

        #expect(fallbackCalls == 1)
        #expect((attachment.base as? IntentFileFailureAttachment)?.altText == "from-fallback")
    }

    // MARK: - Thumbnail sizing

    @Test func attachmentSizeIsFixedSquare() {
        let side = SquareImageThumbnail.transcriptSide
        #expect(
            IntentFileImageAttachment.thumbnailSize(proposedWidth: 1000)
                == CGSize(width: side, height: side)
        )
        #expect(
            IntentFileImageAttachment.thumbnailSize(proposedWidth: nil)
                == CGSize(width: side, height: side)
        )
    }

    @Test func attachmentSizeClampsToNarrowProposals() {
        #expect(
            IntentFileImageAttachment.thumbnailSize(proposedWidth: 100)
                == CGSize(width: 100, height: 100)
        )
    }
}
