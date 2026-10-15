import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceTextFileLoaderTests {
    @Test func utf8SplitAcrossChunksLoadsAndCachesOriginalShareFile() async throws {
        let content = "é — 日本語 👩🏽‍💻\r\nSecond line\n"
        let bytes = Data(content.utf8)
        let connection = FakeConnectionManager()
        connection.responseQueueMap["file.readChunk"] = [
            Self.chunk(Data(bytes.prefix(1)), size: bytes.count),
            Self.chunk(Data(bytes.dropFirst()), size: bytes.count)
        ]
        let loader = WorkspaceFileImageLoader(connection: connection)
        let file = try await loader.text(workspaceId: "linked", path: "reports/Review notes.TXT")
        #expect(file.content == content)
        #expect(file.byteCount == bytes.count)
        #expect(file.url.lastPathComponent == "Review notes.TXT")
        #expect(try Data(contentsOf: file.url) == bytes)
        let cached = try await loader.text(workspaceId: "linked", path: "reports/Review notes.TXT")
        #expect(cached === file)
        let requests = connection.paramsForMethod("file.readChunk")
        #expect(requests.map { $0["offset"] as? Int } == [0, 1])
        #expect(requests.allSatisfy { $0["workspaceId"] as? String == "linked" })
        #expect(requests.allSatisfy { $0["path"] as? String == "reports/Review notes.TXT" })
    }

    @Test func emptyTextIsAValidFile() async throws {
        let connection = FakeConnectionManager()
        connection.responseMap["file.readChunk"] = Self.chunk(Data(), size: 0)
        let loader = WorkspaceFileImageLoader(connection: connection)
        let file = try await loader.text(workspaceId: "ws", path: "empty.txt")
        #expect(file.content.isEmpty)
        #expect(try Data(contentsOf: file.url).isEmpty)
    }

    @Test func fileAtFiveMiBLimitLoadsCompletely() async throws {
        let limit = 5 * 1024 * 1024
        let chunkSize = 256 * 1024
        let bytes = Data(repeating: 0x61, count: chunkSize)
        let connection = FakeConnectionManager()
        connection.responseQueueMap["file.readChunk"] = Array(repeating: Self.chunk(bytes, size: limit), count: limit / chunkSize)
        let loader = WorkspaceFileImageLoader(connection: connection)
        let file = try await loader.text(workspaceId: "ws", path: "large.txt")
        #expect(file.content == String(repeating: "a", count: limit))
        #expect(file.byteCount == limit)
        #expect(try file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize == limit)
        #expect(connection.paramsForMethod("file.readChunk").map { $0["offset"] as? Int } == Array(stride(from: 0, to: limit, by: chunkSize)))
    }

    @Test(arguments: ["missing", "oversized", "non-utf8", "nul-byte", "partial"], ["notes.txt", "page.html"])
    func unavailableFilesAreCachedUntilRetry(_ failure: String, path: String) async throws {
        let connection = FakeConnectionManager()
        let expectedError: WorkspaceFileImageLoader.LoadError?
        switch failure {
        case "missing":
            connection.errorMap["file.readChunk"] = URLError(.fileDoesNotExist)
            expectedError = nil
        case "oversized":
            connection.responseMap["file.readChunk"] = Self.chunk(Data([0x61]), size: 5 * 1024 * 1024 + 1)
            expectedError = .fileTooLarge
        case "non-utf8":
            connection.responseMap["file.readChunk"] = Self.chunk(Data([0xC3, 0x28]), size: 2)
            expectedError = .notUTF8Text
        case "nul-byte":
            let bytes = Data("SQLite format 3\0".utf8)
            connection.responseMap["file.readChunk"] = Self.chunk(bytes, size: bytes.count)
            expectedError = .notUTF8Text
        default:
            connection.responseMap["file.readChunk"] = Self.chunk(Data(), size: 1)
            expectedError = .malformedResponse
        }
        let loader = WorkspaceFileImageLoader(connection: connection)
        do {
            _ = try await loader.text(workspaceId: "ws", path: path)
            Issue.record("An unavailable text file must not load")
        } catch {
            if let expectedError {
                #expect(error as? WorkspaceFileImageLoader.LoadError == expectedError)
            } else {
                #expect((error as? URLError)?.code == .fileDoesNotExist)
            }
        }
        let bytes = Data("Recovered text".utf8)
        connection.errorMap["file.readChunk"] = nil
        connection.responseMap["file.readChunk"] = Self.chunk(bytes, size: bytes.count)
        await #expect(throws: WorkspaceFileImageLoader.LoadError.previouslyFailed) {
            _ = try await loader.text(workspaceId: "ws", path: path)
        }
        #expect(connection.paramsForMethod("file.readChunk").count == 1)
        loader.forgetFailure(workspaceId: "ws", path: path)
        let recovered = try await loader.text(workspaceId: "ws", path: path)
        #expect(recovered.content == "Recovered text")
        #expect(connection.paramsForMethod("file.readChunk").count == 2)
    }

    @Test func retryIsWorkspaceScopedAndBackendCachesAreIndependent() async throws {
        let connection = FakeConnectionManager()
        connection.errorMap["file.readChunk"] = URLError(.timedOut)
        let loader = WorkspaceFileImageLoader(connection: connection)
        for workspace in ["current", "linked"] {
            await #expect(throws: URLError.self) { _ = try await loader.text(workspaceId: workspace, path: "notes.txt") }
        }
        let bytes = Data("Ready".utf8)
        connection.errorMap["file.readChunk"] = nil
        connection.responseMap["file.readChunk"] = Self.chunk(bytes, size: bytes.count)
        loader.forgetFailure(workspaceId: "linked", path: "notes.txt")
        let recovered = try await loader.text(workspaceId: "linked", path: "notes.txt")
        #expect(recovered.content == "Ready")
        await #expect(throws: WorkspaceFileImageLoader.LoadError.previouslyFailed) {
            _ = try await loader.text(workspaceId: "current", path: "notes.txt")
        }
        let otherConnection = FakeConnectionManager()
        let otherBytes = Data("Other backend".utf8)
        otherConnection.responseMap["file.readChunk"] = Self.chunk(otherBytes, size: otherBytes.count)
        let otherLoader = WorkspaceFileImageLoader(connection: otherConnection)
        let otherFile = try await otherLoader.text(workspaceId: "linked", path: "notes.txt")
        #expect(otherFile.content == "Other backend")
    }

    @Test func shareFileLivesUntilLastViewerAndCacheOwnerReleaseIt() async throws {
        let bytes = Data("Share me".utf8)
        let connection = FakeConnectionManager()
        connection.responseMap["file.readChunk"] = Self.chunk(bytes, size: bytes.count)
        var loader: WorkspaceFileImageLoader? = WorkspaceFileImageLoader(connection: connection)
        var file = try await loader?.text(workspaceId: "ws", path: "notes.txt")
        let url = try #require(file?.url)
        loader = nil
        #expect(try withExtendedLifetime(file) { try Data(contentsOf: url) } == bytes)
        file = nil
        try await waitUntil("text file directory removed after its final owner releases it") {
            !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path)
        }
    }

    private static func chunk(_ data: Data, size: Int) -> [String: Any] {
        ["content": data.base64EncodedString(), "bytesRead": data.count, "size": size]
    }
}
