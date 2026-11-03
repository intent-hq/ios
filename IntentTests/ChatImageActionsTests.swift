import Foundation
import Photos
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

    // MARK: - Save outcomes (#463)

    private struct WriteFailure: Error {}

    private static func saveOutcome(
        status: PHAuthorizationStatus,
        writeFails: Bool = false
    ) async -> (outcome: ChatImageSaveOutcome, wrote: Bool) {
        var wrote = false
        let outcome = await ChatImageSaver.save(
            UIImage(),
            requestAuthorization: { status },
            write: { _ in
                wrote = true
                if writeFails { throw WriteFailure() }
            }
        )
        return (outcome, wrote)
    }

    @Test func saveSucceedsWithFullOrLimitedAccess() async {
        for status in [PHAuthorizationStatus.authorized, .limited] {
            let result = await Self.saveOutcome(status: status)
            #expect(result.outcome == .saved)
            #expect(result.wrote)
            #expect(result.outcome.failureMessage == nil)
        }
    }

    @Test func saveReportsDenialWithoutWriting() async {
        for status in [PHAuthorizationStatus.denied, .restricted] {
            let result = await Self.saveOutcome(status: status)
            #expect(result.outcome == .denied)
            #expect(!result.wrote)
            #expect(result.outcome.failureMessage == "Allow Intent to add photos in Settings to save this image.")
        }
    }

    @Test func saveReportsWriteFailure() async {
        let result = await Self.saveOutcome(status: .authorized, writeFails: true)
        #expect(result.outcome == .failed)
        #expect(result.outcome.failureMessage == "Couldn't save this image. Try again.")
    }

    @Test func saveAlertShowsFailureAndClearsOnSuccessfulRetry() async {
        let model = ImageSaveAlertModel()
        var outcome = ChatImageSaveOutcome.failed
        model.saveImage = { _ in outcome }
        let image = UIImage()

        await model.save(image)
        #expect(model.failure?.outcome == .failed)
        #expect(model.failure?.image === image, "retry needs the same image")

        outcome = .saved
        await model.save(image)
        #expect(model.failure == nil)

        outcome = .denied
        await model.save(image)
        #expect(model.failure?.outcome == .denied)
    }
}
