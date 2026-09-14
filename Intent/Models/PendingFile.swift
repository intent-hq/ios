import Foundation

/// A file picked from the Files app, pending in the composer until send time.
/// Security-scoped access is owned by `ConversationAttachmentPipeline`, not by
/// this value.
struct PendingFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let displayName: String
    let size: Int64?

    /// Human-readable size for the composer chip, nil when size is unavailable.
    var formattedSize: String? {
        guard let size else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
