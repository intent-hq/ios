import SwiftUI
import Testing
import UIKit

@testable import Intent

/// Consumer layout regressions, rather than assertions about individual tokens.
@MainActor
struct ConversationContentLayoutTests {
    @Test func transcriptThumbnailMatchesMarkdownAttachmentSize() throws {
        let image = try #require(UIImage(systemName: "photo"))
        let rendered = measuredSize(SquareImageThumbnail(image: image, side: SquareImageThumbnail.transcriptSide))

        #expect(rendered == CGSize(width: 160, height: 160))
        #expect(IntentFileImageAttachment.thumbnailSize(proposedWidth: nil) == rendered)
        #expect(IntentFileImageAttachment.thumbnailSize(proposedWidth: 1000) == rendered)
        #expect(IntentFileImageAttachment.thumbnailSize(proposedWidth: 100) == CGSize(width: 100, height: 100))
    }

    @Test func userAttachmentRendersAtGridThumbnailSize() throws {
        let image = try #require(UIImage(systemName: "photo"))
        let data = try #require(image.pngData())
        let json = #"{"type":"image","data":"\#(data.base64EncodedString())","mimeType":"image/png"}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
        let rendered = measuredSize(ImageAttachmentThumbnail(block: block, workspaceId: "layout-test"))

        #expect(rendered == CGSize(width: 60, height: 60))
        #expect(rendered.width == ImageAttachmentThumbnail.side)
    }

    @Test func pendingAttachmentsReserveTheLoadedImageSize() throws {
        let image = try #require(UIImage(systemName: "photo"))
        let connection = FakeConnectionManager()
        let loader = AttachmentImageLoader(
            connection: connection,
            fileLoader: WorkspaceFileImageLoader(connection: connection)
        )
        for style in [AttachmentReferenceImageView.Style.inline, .thumbnail] {
            let side = style == .inline ? SquareImageThumbnail.transcriptSide : ImageAttachmentThumbnail.side
            let loaded = measuredSize(SquareImageThumbnail(image: image, side: side))
            let pending = AttachmentReferenceImageView(
                workspaceId: "layout-test", attachmentId: "pending", style: style, loader: loader
            )
            #expect(measuredSize(pending) == loaded)
            #expect(measuredSize(pending, dynamicTypeSize: .accessibility3) == loaded)
        }
    }

    @Test func decodeFailureLabelGrowsWithDynamicType() {
        let regular = measuredSize(ImageDecodeFailureView())
        let accessible = measuredSize(ImageDecodeFailureView(), dynamicTypeSize: .accessibility3)

        #expect(regular.width > 0 && regular.height > 0)
        #expect(accessible.width > regular.width)
        #expect(accessible.height > regular.height)
    }

    @Test func contextChipFlowPreservesWrappingSpacing() {
        let chipWidth: CGFloat = 40
        let chipHeight: CGFloat = 20
        let rowWidth: CGFloat = 90
        let layout = Self.chipLayout()
        let flow = layout {
            Color.clear.frame(width: chipWidth, height: chipHeight)
            Color.clear.frame(width: chipWidth, height: chipHeight)
            Color.clear.frame(width: chipWidth, height: chipHeight)
        }
        .frame(width: rowWidth)

        #expect(measuredSize(flow) == CGSize(width: 90, height: 46))
    }

    /// `Layout` is Sendable; its default spacing must remain usable off-main.
    nonisolated private static func chipLayout() -> ChipFlowLayout {
        ChipFlowLayout()
    }

    @Test func compactHeadingsRetainTheirRelativeRenderedSizes() {
        let first = measuredSize(MarkdownTextView(text: "# Heading"))
        let second = measuredSize(MarkdownTextView(text: "## Heading"))
        let third = measuredSize(MarkdownTextView(text: "### Heading"))
        let fifth = measuredSize(MarkdownTextView(text: "##### Heading"))
        let sixth = measuredSize(MarkdownTextView(text: "###### Heading"))

        #expect(first.height > second.height)
        #expect(second.height > third.height)
        #expect(fifth.height == sixth.height)
        #expect(third.height > 0)
    }

    @Test func codeAndTableContentRemainWidthBoundedAndScaleWithDynamicType() {
        let markdown = """
        # Heading

        A paragraph with `inline code`.

        ```swift
        let value = 1
        print(value)
        ```

        | Name | Value |
        | --- | --- |
        | Item | One |

        > Quoted text

        - [ ] Task
        """
        let regular = measuredSize(MarkdownTextView(text: markdown))
        let accessible = measuredSize(MarkdownTextView(text: markdown), dynamicTypeSize: .accessibility3)

        #expect(regular.width == Self.proposedWidth)
        #expect(accessible.width == Self.proposedWidth)
        #expect(regular.height > 0)
        #expect(accessible.height > regular.height)
    }

    private static let proposedWidth: CGFloat = 320
    private static let proposedHeight: CGFloat = 10_000

    private func measuredSize<Content: View>(
        _ content: Content,
        dynamicTypeSize: DynamicTypeSize = .large
    ) -> CGSize {
        let host = UIHostingController(rootView: content
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            .environment(\.colorScheme, .light))
        return host.sizeThatFits(in: CGSize(width: Self.proposedWidth, height: Self.proposedHeight))
    }
}
