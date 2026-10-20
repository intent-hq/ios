import Foundation
@testable import Intent
import SwiftUI
import Testing
@testable import Textual
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

    @Test func shortIntentFileLinkWithoutWorkspaceYieldsPlaceholder() async throws {
        let log = FileImageFetchLog()
        var loader = IntentFileAttachmentLoader(workspaceId: nil, fallback: .image())
        loader.fileImage = { workspaceId, path in
            await log.record(workspaceId, path)
            return UIImage()
        }
        var fallbackCalls = 0

        let attachment = try await loader.resolvedAttachment(
            for: URL(string: "intent://local/file/pic.png")!,
            text: "missing workspace"
        ) {
            fallbackCalls += 1
            return AnyAttachment(IntentFileFailureAttachment(altText: "from-fallback"))
        }

        #expect(log.entries.isEmpty)
        #expect(fallbackCalls == 0)
        #expect((attachment.base as? IntentFileFailureAttachment)?.altText == "missing workspace")
    }

    @Test func nonImageIntentFileLinkYieldsPlaceholderWithoutFetching() async throws {
        let log = FileImageFetchLog()
        var loader = IntentFileAttachmentLoader(workspaceId: "ws-1", fallback: .image())
        loader.fileImage = { workspaceId, path in
            await log.record(workspaceId, path)
            return UIImage()
        }

        let attachment = try await loader.resolvedAttachment(
            for: URL(string: "intent://local/file/readme.txt")!,
            text: "not an image"
        ) {
            Issue.record("intent-file links must not consult the fallback loader")
            return AnyAttachment(IntentFileFailureAttachment(altText: "from-fallback"))
        }

        #expect(log.entries.isEmpty)
        #expect((attachment.base as? IntentFileFailureAttachment)?.altText == "not an image")
    }

    @Test func intentFileCancellationYieldsPlaceholderWithoutFallback() async throws {
        var loader = IntentFileAttachmentLoader(workspaceId: "ws-1", fallback: .image())
        loader.fileImage = { _, _ in throw CancellationError() }
        var fallbackCalls = 0

        let attachment = try await loader.resolvedAttachment(
            for: URL(string: "intent://local/file/pic.png")!,
            text: "cancelled"
        ) {
            fallbackCalls += 1
            return AnyAttachment(IntentFileFailureAttachment(altText: "from-fallback"))
        }

        #expect(fallbackCalls == 0)
        #expect((attachment.base as? IntentFileFailureAttachment)?.altText == "cancelled")
    }

    @Test func longIntentFileLinkUsesEmbeddedWorkspaceAndPath() async throws {
        let image = UIImage()
        let log = FileImageFetchLog()
        var loader = IntentFileAttachmentLoader(workspaceId: "window-workspace", fallback: .image())
        loader.fileImage = { workspaceId, path in
            await log.record(workspaceId, path)
            return image
        }

        _ = try await loader.resolvedAttachment(
            for: URL(string: "intent://local/link-workspace/file/a/b.png")!,
            text: "alt"
        ) {
            Issue.record("intent-file links must not consult the fallback loader")
            return AnyAttachment(IntentFileFailureAttachment(altText: "from-fallback"))
        }

        #expect(log.entries.count == 1)
        #expect(log.entries.first?.workspaceId == "link-workspace")
        #expect(log.entries.first?.path == "a/b.png")
    }

    @Test func intentFileFetchFailureYieldsPlaceholderWithoutFallback() async throws {
        struct FetchFailure: Error {}
        var loader = IntentFileAttachmentLoader(workspaceId: "ws-1", fallback: .image())
        loader.fileImage = { _, _ in throw FetchFailure() }

        let attachment = try await loader.resolvedAttachment(
            for: URL(string: "intent://local/file/pic.png")!,
            text: "failed"
        ) {
            Issue.record("intent-file links must not consult the fallback loader")
            return AnyAttachment(IntentFileFailureAttachment(altText: "from-fallback"))
        }

        #expect((attachment.base as? IntentFileFailureAttachment)?.altText == "failed")
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

    @Test func remoteCancellationDelegatesToFallbackLoader() async throws {
        let loader = IntentFileAttachmentLoader(
            workspaceId: nil,
            fallback: .image()
        ) { _ in throw CancellationError() }
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

    @Test func mediaCardSizeIsFixedSquare() {
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

extension IntentFileAttachmentLoaderTests {
    @Test func inlineImageSizesFitTheFullImage() {
        #expect(InlineImageThumbnail.size(for: CGSize(width: 400, height: 200)) == CGSize(width: 160, height: 80))
        #expect(InlineImageThumbnail.size(for: CGSize(width: 200, height: 400)) == CGSize(width: 80, height: 160))
        #expect(InlineImageThumbnail.size(for: CGSize(width: 200, height: 200)) == CGSize(width: 160, height: 160))
        #expect(InlineImageThumbnail.size(for: CGSize(width: 400, height: 200), proposedWidth: 60) == CGSize(width: 60, height: 30))
        #expect(InlineImageThumbnail.size(for: CGSize(width: 200, height: 400), proposedWidth: 60) == CGSize(width: 60, height: 120))
        #expect(InlineImageThumbnail.size(for: .zero) == CGSize(width: 160, height: 160))
        #expect(InlineImageThumbnail.size(for: CGSize(width: 400, height: 200), proposedWidth: 0) == .zero)
    }

    @Test(arguments: [
        CGSize(width: 400, height: 200),
        CGSize(width: 200, height: 400),
        CGSize(width: 200, height: 200)
    ])
    func imageSymbolShowsFullImageWhenScaledIntoText(_ sourceSize: CGSize) throws {
        let source = UIGraphicsImageRenderer(size: sourceSize).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: sourceSize))
            UIColor.red.setFill()
            context.fill(CGRect(
                x: sourceSize.width / 2 - 50,
                y: sourceSize.height / 2 - 50,
                width: 100,
                height: 100
            ))
        }
        let attachment = IntentFileImageAttachment(image: source, altText: "Proportions fixture")
        let symbol = try #require(ImageRenderer(content: attachment.body).uiImage)
        #expect(max(symbol.size.width, symbol.size.height) == 160)
        #expect(symbol.size.width / symbol.size.height == sourceSize.width / sourceSize.height)

        for width: CGFloat in [160, 60] {
            let bounds = CGRect(origin: .zero, size: attachment.sizeThatFits(
                ProposedViewSize(width: width, height: nil), in: TextEnvironmentValues()
            ))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let rendered = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
                symbol.draw(in: bounds)
            }
            let marker = try redMarkerSize(in: rendered)
            let scale = min(width / sourceSize.width, 160 / sourceSize.height)
            #expect(bounds.size == CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale))
            #expect(abs(marker.width - 100 * scale) <= 1)
            #expect(abs(marker.height - 100 * scale) <= 1)
        }
    }

    private func redMarkerSize(in image: UIImage) throws -> CGSize {
        let bitmap = try #require(image.cgImage)
        let channels = 4
        let bitsPerComponent = 8
        let redThreshold: UInt8 = 200
        let otherThreshold: UInt8 = 50
        var pixels = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * channels)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(
                data: bytes.baseAddress,
                width: bitmap.width,
                height: bitmap.height,
                bitsPerComponent: bitsPerComponent,
                bytesPerRow: bitmap.width * channels,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        }
        func isRed(x: Int, y: Int) -> Bool {
            let offset = (y * bitmap.width + x) * channels
            return pixels[offset] > redThreshold
                && pixels[offset + 1] < otherThreshold && pixels[offset + 2] < otherThreshold
        }
        let horizontal = (0..<bitmap.width).filter { isRed(x: $0, y: bitmap.height / 2) }.count
        let vertical = (0..<bitmap.height).filter { isRed(x: bitmap.width / 2, y: $0) }.count
        return CGSize(width: horizontal, height: vertical)
    }

    @Test(arguments: [nil, .regular, .bold] as [LegibilityWeight?])
    nonisolated func failurePlaceholderSizeTracksDynamicType(_ weight: LegibilityWeight?) {
        let attachment = IntentFileFailureAttachment(altText: "unavailable")
        let standard = attachment.sizeThatFits(
            .unspecified, in: TextEnvironmentValues(dynamicTypeSize: .large, legibilityWeight: weight)
        )
        let accessible = attachment.sizeThatFits(
            .unspecified, in: TextEnvironmentValues(dynamicTypeSize: .accessibility5, legibilityWeight: weight)
        )

        #expect(standard.width > 0 && standard.height > 0)
        #expect(accessible.width > standard.width)
        #expect(accessible.height > standard.height)
    }

    @Test nonisolated func failurePlaceholderDefaultsToRegularLegibility() {
        let attachment = IntentFileFailureAttachment(altText: "unavailable")
        let regular = attachment.sizeThatFits(.unspecified, in: TextEnvironmentValues(legibilityWeight: .regular))
        let unspecified = attachment.sizeThatFits(.unspecified, in: TextEnvironmentValues(legibilityWeight: nil))

        #expect(unspecified == regular)
    }
}
