import Foundation

/// Immutable text and shared file ownership keep Share valid after cache eviction.
nonisolated final class WorkspaceTextFile: Sendable {
    let url: URL
    let content: String
    let byteCount: Int
    let lineIndex: FileLineIndex
    static let maxBytes = 5 * 1024 * 1024 // swiftlint:disable:this no_magic_numbers

    private init(url: URL, content: String, byteCount: Int) {
        self.url = url
        self.content = content
        self.byteCount = byteCount
        lineIndex = FileLineIndex(content)
    }

    deinit {
        Task.detached(priority: .utility) { [url] in
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    /// Download and strict decoding stay off the UI executor. Preserve the name
    /// in an owned, unique directory so the share sheet exports the original name.
    @concurrent
    static func load(path: String, download: @Sendable (FileHandle) async throws -> Int) async throws -> WorkspaceTextFile {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-text-\(UUID())", isDirectory: true)
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
        guard byteCount <= maxBytes else { throw WorkspaceFileImageLoader.LoadError.fileTooLarge }
        let data = try Data(contentsOf: url)
        guard !data.contains(0), let content = String(data: data, encoding: .utf8) else {
            throw WorkspaceFileImageLoader.LoadError.notUTF8Text
        }
        try Task.checkCancellation()
        let file = WorkspaceTextFile(url: url, content: content, byteCount: byteCount)
        retained = true
        return file
    }
}
