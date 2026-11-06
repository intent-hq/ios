import Foundation
@testable import Intent
import Testing

/// The media preview names the real cause of a failure instead of always
/// blaming the connection, and offers Retry only where it can help.
@MainActor
struct WorkspaceFilePreviewFailureTests {
    private typealias Failure = WorkspaceFilePreview.Failure
    private typealias LoadError = WorkspaceFileImageLoader.LoadError

    @Test func tooLargeImageNamesTheImageLimitWithoutRetry() {
        let failure = Failure(LoadError.fileTooLarge, isImage: true, path: "docs/big.png")
        #expect(failure == .tooLarge(limit: WorkspaceFileImageLoader.maxFileBytes))
        #expect(!failure.canRetry)
        #expect(failure.message.contains("too large"))
        #expect(failure.message.contains(ByteCountFormatter.string(fromByteCount: Int64(WorkspaceFileImageLoader.maxFileBytes), countStyle: .memory)))
        #expect(!failure.message.contains("connection"))
    }

    @Test func tooLargeVideoNamesTheVideoLimit() {
        #expect(Failure(LoadError.fileTooLarge, isImage: false, path: "docs/big.mov") == .tooLarge(limit: ImportedPhotoVideo.maxBytes))
    }

    @Test func webMVideoIsUnsupported() {
        let failure = Failure(LoadError.notAVideo, isImage: false, path: "docs/clip.webm")
        #expect(failure == .unsupported)
        #expect(failure.message.contains("cannot be previewed"))
        #expect(!failure.message.contains("connection"))
    }

    @Test(arguments: ["docs/photo.png", "docs/clip.mov"])
    func supportedTypeThatFailsToDecodeIsDamagedWithoutRetry(_ path: String) {
        let isImage = path.hasSuffix(".png")
        let error: LoadError = isImage ? .notAnImage : .notAVideo
        let failure = Failure(error, isImage: isImage, path: path)
        #expect(failure == .damaged)
        #expect(!failure.canRetry)
        #expect(failure.message.contains("may be damaged"))
        #expect(!failure.message.contains("cannot be previewed"))
        #expect(!failure.message.contains("connection"))
    }

    @Test func malformedReplyIsAnUnexpectedResponseWithRetry() {
        let failure = Failure(LoadError.malformedResponse, isImage: true, path: "docs/photo.png")
        #expect(failure == .unexpectedResponse)
        #expect(failure.canRetry)
        #expect(failure.message.contains("unexpected response"))
        #expect(!failure.message.contains("connection"))
    }

    @Test(arguments: [URLError(.timedOut) as any Error, LoadError.previouslyFailed])
    func requestFailureMentionsTheConnection(_ error: any Error) {
        let failure = Failure(error, isImage: true, path: "docs/photo.png")
        #expect(failure == .unavailable)
        #expect(failure.canRetry)
        #expect(failure.message.contains("connection"))
    }
}
