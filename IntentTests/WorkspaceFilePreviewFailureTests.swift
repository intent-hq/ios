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
        let failure = Failure(LoadError.fileTooLarge, isImage: true)
        #expect(failure == .tooLarge(limit: WorkspaceFileImageLoader.maxFileBytes))
        #expect(!failure.canRetry)
        #expect(failure.message.contains("too large"))
        #expect(failure.message.contains(ByteCountFormatter.string(fromByteCount: Int64(WorkspaceFileImageLoader.maxFileBytes), countStyle: .memory)))
        #expect(!failure.message.contains("connection"))
    }

    @Test func tooLargeVideoNamesTheVideoLimit() {
        #expect(Failure(LoadError.fileTooLarge, isImage: false) == .tooLarge(limit: ImportedPhotoVideo.maxBytes))
    }

    @Test(arguments: [LoadError.notAnImage, .notAVideo])
    func undecodableFileIsUnsupported(_ error: WorkspaceFileImageLoader.LoadError) {
        let failure = Failure(error, isImage: error == .notAnImage)
        #expect(failure == .unsupported)
        #expect(failure.canRetry)
        #expect(failure.message.contains("cannot be previewed"))
        #expect(!failure.message.contains("connection"))
    }

    @Test(arguments: [URLError(.timedOut) as any Error, LoadError.malformedResponse, LoadError.previouslyFailed])
    func requestFailureMentionsTheConnection(_ error: any Error) {
        let failure = Failure(error, isImage: true)
        #expect(failure == .unavailable)
        #expect(failure.canRetry)
        #expect(failure.message.contains("connection"))
    }
}
