import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceDocumentLoaderTests {
    @Test func chunkedDocumentKeepsItsOriginalNameAndIsCached() async throws {
        let bytes = Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0xFF])
        let connection = FakeConnectionManager()
        connection.responseQueueMap["file.readChunk"] = [
            Self.chunk(Data(bytes.prefix(2)), size: bytes.count),
            Self.chunk(Data(bytes.dropFirst(2)), size: bytes.count)
        ]
        let loader = WorkspaceFileImageLoader(connection: connection)
        let document = try await loader.document(workspaceId: "linked", path: "reports/Budget 2026.XLSX")
        #expect(document.name == "Budget 2026.XLSX")
        #expect(document.url.lastPathComponent == "Budget 2026.XLSX")
        #expect(document.byteCount == bytes.count)
        #expect(try Data(contentsOf: document.url) == bytes)
        let cached = try await loader.document(workspaceId: "linked", path: "reports/Budget 2026.XLSX")
        #expect(cached === document)
        let requests = connection.paramsForMethod("file.readChunk")
        #expect(requests.map { $0["offset"] as? Int } == [0, 2])
        #expect(requests.allSatisfy { $0["workspaceId"] as? String == "linked" })
        #expect(requests.allSatisfy { $0["path"] as? String == "reports/Budget 2026.XLSX" })
    }

    @Test(arguments: ["missing", "oversized", "partial"])
    func unavailableDocumentsAreCachedUntilRetry(_ failure: String) async throws {
        let connection = FakeConnectionManager()
        let expectedError: WorkspaceFileImageLoader.LoadError?
        switch failure {
        case "missing":
            connection.errorMap["file.readChunk"] = URLError(.fileDoesNotExist)
            expectedError = nil
        case "oversized":
            connection.responseMap["file.readChunk"] = Self.chunk(Data([0x50]), size: WorkspaceDocument.maxBytes + 1)
            expectedError = .fileTooLarge
        default:
            connection.responseMap["file.readChunk"] = Self.chunk(Data(), size: 1)
            expectedError = .malformedResponse
        }
        let loader = WorkspaceFileImageLoader(connection: connection)
        do {
            _ = try await loader.document(workspaceId: "ws", path: "budget.xlsx")
            Issue.record("An unavailable document must not load")
        } catch {
            if let expectedError {
                #expect(error as? WorkspaceFileImageLoader.LoadError == expectedError)
            } else {
                #expect((error as? URLError)?.code == .fileDoesNotExist)
            }
        }
        let bytes = Data([0x50, 0x4B])
        connection.errorMap["file.readChunk"] = nil
        connection.responseMap["file.readChunk"] = Self.chunk(bytes, size: bytes.count)
        await #expect(throws: WorkspaceFileImageLoader.LoadError.previouslyFailed) {
            _ = try await loader.document(workspaceId: "ws", path: "budget.xlsx")
        }
        #expect(connection.paramsForMethod("file.readChunk").count == 1)
        loader.forgetFailure(workspaceId: "ws", path: "budget.xlsx")
        let recovered = try await loader.document(workspaceId: "ws", path: "budget.xlsx")
        #expect(try Data(contentsOf: recovered.url) == bytes)
        #expect(connection.paramsForMethod("file.readChunk").count == 2)
    }

    @Test func temporaryFileLivesUntilLastViewerAndCacheOwnerReleaseIt() async throws {
        let bytes = Data([0x50, 0x4B])
        let connection = FakeConnectionManager()
        connection.responseMap["file.readChunk"] = Self.chunk(bytes, size: bytes.count)
        var loader: WorkspaceFileImageLoader? = WorkspaceFileImageLoader(connection: connection)
        var document = try await loader?.document(workspaceId: "ws", path: "budget.xlsx")
        let url = try #require(document?.url)
        loader = nil
        #expect(try withExtendedLifetime(document) { try Data(contentsOf: url) } == bytes)
        document = nil
        try await waitUntil("document directory removed after its final owner releases it") {
            !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path)
        }
    }

    private static func chunk(_ data: Data, size: Int) -> [String: Any] {
        ["content": data.base64EncodedString(), "bytesRead": data.count, "size": size]
    }
}
