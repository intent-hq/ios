import Foundation

struct PendingFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let displayName: String
    let size: Int64?
    let video: ImportedPhotoVideo?

    init(url: URL, displayName: String, size: Int64?, video: ImportedPhotoVideo? = nil) {
        self.url = url
        self.displayName = displayName
        self.size = size
        self.video = video
    }

    var formattedSize: String? {
        guard let size else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
