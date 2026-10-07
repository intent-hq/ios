import Foundation

/// A file picked from Files or Photos, pending in the composer until send time.
/// Security-scoped access is owned by `ConversationAttachmentPipeline`, not by
/// this value.
struct PendingFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let displayName: String
    let size: Int64?
    /// Retained by every copy, including an in-flight or recoverable send.
    let video: ImportedPhotoVideo?

    init(url: URL, displayName: String, size: Int64?, video: ImportedPhotoVideo? = nil) {
        self.url = url
        self.displayName = displayName
        self.size = size
        self.video = video
    }

    /// Human-readable size for the composer chip, nil when size is unavailable.
    var formattedSize: String? {
        guard let size else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
