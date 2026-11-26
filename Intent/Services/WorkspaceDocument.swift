import Foundation

nonisolated final class WorkspaceDocument: Sendable {
    let url: URL
    let byteCount: Int
    static let maxBytes = ImportedPhotoVideo.maxBytes
    static let pathExtensions: Set<String> = ["doc", "docx", "key", "numbers", "pages", "ppt", "pptx", "xls", "xlsx"]

    var name: String { url.lastPathComponent }

    private init(url: URL, byteCount: Int) {
        self.url = url
        self.byteCount = byteCount
    }

    deinit {
        Task.detached(priority: .utility) { [url] in
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    static func isDocument(path: String) -> Bool {
        pathExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    @concurrent
    static func load(path: String, download: @Sendable (FileHandle) async throws -> Int) async throws -> WorkspaceDocument {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-document-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: directory) } }
        let url = directory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        try Data().write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let byteCount = try await download(handle)
        try handle.close()
        try Task.checkCancellation()
        let document = WorkspaceDocument(url: url, byteCount: byteCount)
        retained = true
        return document
    }
}
