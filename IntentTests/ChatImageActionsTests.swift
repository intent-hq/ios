import Foundation
import Testing
import UIKit

@testable import Intent

/// Covers the chat-image action menu helpers: info-row formatting and the
/// image block's base64 payload decoding.
struct ChatImageActionsTests {
    // MARK: - Dimensions formatting

    @Test func dimensionsTextFormatsPixels() {
        #expect(ImageInfoFormat.dimensionsText(pixelWidth: 800, pixelHeight: 600) == "800 × 600")
    }

    @Test func dimensionsTextConvertsPointsToPixelsViaScale() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 10, height: 20), format: format
        ).image { _ in }

        #expect(ImageInfoFormat.dimensionsText(for: image) == "20 × 40")
    }

    @Test func dimensionsTextUsesScaleOneForDecodedImages() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = UIGraphicsImageRenderer(
            size: CGSize(width: 3, height: 5), format: format
        ).pngData { _ in }
        let decoded = try #require(UIImage(data: png))

        #expect(ImageInfoFormat.dimensionsText(for: decoded) == "3 × 5")
    }

    // MARK: - File-size formatting

    @Test func byteCountTextIsNonEmptyAndSizeDependent() {
        let small = ImageInfoFormat.byteCountText(1024)
        let large = ImageInfoFormat.byteCountText(1_500_000)
        #expect(!small.isEmpty)
        #expect(!large.isEmpty)
        #expect(small != large)
    }

    // MARK: - Base64 payload decoding

    @Test func decodeImageDataRoundtripsBase64() throws {
        let payload = Data("hello".utf8)
        let json = #"{"type":"image","data":"\#(payload.base64EncodedString())","mimeType":"image/png"}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))

        #expect(ContentBlockView.decodeImageData(block) == payload)
    }

    @Test func decodeImageDataRejectsInvalidBase64() throws {
        let json = #"{"type":"image","data":"not base64!!","mimeType":"image/png"}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))

        #expect(ContentBlockView.decodeImageData(block) == nil)
    }

    @Test func decodeImageDataIsNilWithoutPayload() throws {
        let json = #"{"type":"image","attachmentId":"att-1","mimeType":"image/png"}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))

        #expect(ContentBlockView.decodeImageData(block) == nil)
    }
}
