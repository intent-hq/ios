import Foundation

/// Only the writer actor calls this synchronous file API. The injectable
/// boundary is for storage-failure tests, not for event producers.
nonisolated protocol DiagnosticStorage: Sendable {
    func prepare() throws
    func readHistory(maximumBytes: Int) throws -> Data
    func replaceHistory(_ data: Data) throws
    func clearHistory() throws
    func clearReports() throws
    func prepareReport(snapshot: DiagnosticSnapshot) throws -> URL
}

nonisolated struct DiagnosticFileStorage: DiagnosticStorage {
    enum Failure: Error {
        case oversizedHistory, unsafeFile
    }

    let directory: URL
    private var history: URL { directory.appendingPathComponent("events.jsonl") }
    private var reports: URL { directory.appendingPathComponent("report", isDirectory: true) }

    static var applicationStorage: Self {
        Self(directory: URL.applicationSupportDirectory.appendingPathComponent("IntentDiagnostics-v1", isDirectory: true))
    }

    func prepare() throws { try prepareDirectory(directory) }

    func readHistory(maximumBytes: Int) throws -> Data {
        try rejectSymbolicLink(history)
        guard FileManager.default.fileExists(atPath: history.path) else { return Data() }
        let handle = try FileHandle(forReadingFrom: history)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw Failure.oversizedHistory }
        return data
    }

    func replaceHistory(_ data: Data) throws {
        try prepare()
        try write(data, to: history)
    }

    func clearHistory() throws {
        try rejectSymbolicLink(directory)
        try removeIfPresent(history)
    }

    func clearReports() throws {
        try rejectSymbolicLink(directory)
        try removeIfPresent(reports)
    }

    func prepareReport(snapshot: DiagnosticSnapshot) throws -> URL {
        try prepare()
        try clearReports()
        try prepareDirectory(reports)
        try write(snapshot.jsonLines, to: reports.appendingPathComponent("events.jsonl"))
        try write(snapshot.metadataJSON(), to: reports.appendingPathComponent("metadata.json"))
        return reports
    }

    private func prepareDirectory(_ url: URL) throws {
        try rejectSymbolicLink(url)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        // Apply policy to pre-existing directories too; never sync diagnostics.
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    private func write(_ data: Data, to url: URL) throws {
        try rejectSymbolicLink(url)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    private func rejectSymbolicLink(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { throw Failure.unsafeFile }
    }

    private func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
