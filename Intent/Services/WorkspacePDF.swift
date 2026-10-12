import PDFKit
import UIKit

/// Immutable metadata and thumbnail; PDFKit documents stay confined to the
/// decoding task or viewer. Shared ownership keeps the downloaded file alive.
nonisolated final class WorkspacePDF: Sendable, Hashable {
    let url: URL
    let name: String
    let thumbnail: UIImage
    let pageCount: Int
    let byteCount: Int
    static let maxBytes = ImportedPhotoVideo.maxBytes
    private static let thumbnailScale: CGFloat = 3
    private static let signature = Data("%PDF-".utf8)
    private static let headerSearchLength = 1024

    private init(url: URL, name: String, thumbnail: UIImage, pageCount: Int, byteCount: Int) {
        self.url = url
        self.name = name
        self.thumbnail = thumbnail
        self.pageCount = pageCount
        self.byteCount = byteCount
    }

    deinit {
        Task.detached(priority: .utility) { [url] in
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func == (lhs: WorkspacePDF, rhs: WorkspacePDF) -> Bool { lhs === rhs }

    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    static func isPDF(path: String) -> Bool {
        URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf"
    }

    /// Use the same bounded validation and empty-password unlock when preparing
    /// the thumbnail and reopening the file in the viewer. Encryption alone is
    /// not a reason to reject a PDF; only a still-locked document needs a password.
    static func openDocument(at url: URL) throws -> PDFDocument {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Data.contains tests one byte, not the full signature sequence.
        // swiftlint:disable:next contains_over_range_nil_comparison
        guard let header = try handle.read(upToCount: headerSearchLength), header.range(of: signature) != nil,
              let document = PDFDocument(url: url) else {
            throw WorkspaceFileImageLoader.LoadError.notAPDF
        }
        if document.isLocked, !document.unlock(withPassword: "") {
            throw WorkspaceFileImageLoader.LoadError.pdfPasswordRequired
        }
        guard document.pageCount > 0 else { throw WorkspaceFileImageLoader.LoadError.notAPDF }
        return document
    }

    /// Takes ownership of a completed temporary download, including on failure.
    @concurrent
    static func prepare(fileURL: URL, name: String, byteCount: Int) async throws -> WorkspacePDF {
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: fileURL) } }
        try Task.checkCancellation()
        guard byteCount <= maxBytes else { throw WorkspaceFileImageLoader.LoadError.fileTooLarge }
        let document = try openDocument(at: fileURL)
        guard let page = document.page(at: 0) else {
            throw WorkspaceFileImageLoader.LoadError.notAPDF
        }
        let side = SquareImageThumbnail.transcriptSide * thumbnailScale
        let thumbnail = page.thumbnail(of: CGSize(width: side, height: side), for: .cropBox)
        try Task.checkCancellation()
        let pdf = WorkspacePDF(
            url: fileURL, name: name, thumbnail: thumbnail, pageCount: document.pageCount, byteCount: byteCount
        )
        retained = true
        return pdf
    }
}
