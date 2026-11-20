import PDFKit
import UIKit

nonisolated final class WorkspacePDF: Sendable, Hashable {
    let url: URL
    let name: String
    let shareURL: URL
    let thumbnail: UIImage
    let pageCount: Int
    let byteCount: Int
    static let maxBytes = ImportedPhotoVideo.maxBytes
    private static let thumbnailScale: CGFloat = 3
    private static let signature = Data("%PDF-".utf8)
    private static let headerSearchLength = 1024
    private static let fallbackExportName = "Document.pdf"
    private static let maxExportBaseLength = 200

    private init(url: URL, name: String, shareURL: URL, thumbnail: UIImage, pageCount: Int, byteCount: Int) {
        self.url = url
        self.name = name
        self.shareURL = shareURL
        self.thumbnail = thumbnail
        self.pageCount = pageCount
        self.byteCount = byteCount
    }

    deinit {
        Task.detached(priority: .utility) { [url] in
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: Self.shareDirectory(for: url))
        }
    }

    static func == (lhs: WorkspacePDF, rhs: WorkspacePDF) -> Bool { lhs === rhs }

    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    static func isPDF(path: String) -> Bool {
        URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf"
    }

    static func exportFileName(for name: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/:\\").union(.controlCharacters).union(.newlines)
        var cleaned = String(String.UnicodeScalarView(name.unicodeScalars.map { unsafe.contains($0) ? "-" : $0 }))
            .trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        var base = cleaned
        var pathExtension = "pdf"
        if let dot = cleaned.lastIndex(of: "."), cleaned[cleaned.index(after: dot)...].lowercased() == "pdf" {
            base = String(cleaned[..<dot])
            pathExtension = String(cleaned[cleaned.index(after: dot)...])
        }
        base = String(base.prefix(maxExportBaseLength)).trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return fallbackExportName }
        return base + "." + pathExtension
    }

    static func shareDirectory(for url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-share", isDirectory: true)
    }

    private static func makeShareURL(for url: URL, name: String) -> URL {
        let directory = shareDirectory(for: url)
        let target = directory.appendingPathComponent(exportFileName(for: name), isDirectory: false)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                try fileManager.linkItem(at: url, to: target)
            } catch {
                try fileManager.copyItem(at: url, to: target)
            }
            return target
        } catch {
            try? fileManager.removeItem(at: directory)
            return url
        }
    }

    static func openDocument(at url: URL) throws -> PDFDocument {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
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
            url: fileURL,
            name: name,
            shareURL: makeShareURL(for: fileURL, name: name),
            thumbnail: thumbnail,
            pageCount: document.pageCount,
            byteCount: byteCount
        )
        retained = true
        return pdf
    }
}
