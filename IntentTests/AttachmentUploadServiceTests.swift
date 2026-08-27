import Foundation
import Testing
@testable import Intent

/// Covers attachment placement (PROTOCOL §5.9): the single-shot
/// `file.placeAttachment` path, the chunked `file.attachmentUpload.*`
/// session (chunk math, progress, abort-on-failure), SHA-256 correctness,
/// and the client-side 1 GiB cap.
@MainActor
struct AttachmentUploadServiceTests {
    private typealias UploadError = AttachmentUploadService.UploadError

    /// Canonical daemon placement result (placeAttachment / commit).
    private static func placementResponse(
        fileName: String = "doc.pdf", mimeType: String? = "application/pdf", size: Int = 5
    ) -> [String: Any] {
        var response: [String: Any] = [
            "ok": true,
            "path": ".intent/attachments/\(fileName)",
            "fileName": fileName,
            "size": size,
            "attachmentId": "att-1",
            "uploadedAt": "2026-08-27T00:00:00Z",
        ]
        if let mimeType { response["mimeType"] = mimeType }
        return response
    }

    private static func beginResponse(
        uploadId: String = "up-1", maxChunkBytes: Int = 16 * 1024 * 1024
    ) -> [String: Any] {
        ["uploadId": uploadId, "maxChunkBytes": maxChunkBytes]
    }

    /// Temp file with the given contents; caller need not clean up (unique dir).
    private static func tempFile(_ data: Data, name: String = "payload.bin") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-upload-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: - Single-shot path

    @Test func smallDataPlacesSingleShot() async throws {
        let payload = Data("hello".utf8)
        let fake = FakeConnectionManager()
        fake.responseMap["file.placeAttachment"] = Self.placementResponse()
        let service = AttachmentUploadService(connection: fake)

        let placed = try await service.placeData(
            workspaceId: "ws-1", fileName: "doc.pdf", data: payload,
            mimeType: "application/pdf")

        let params = fake.paramsForMethod("file.placeAttachment")
        #expect(params.count == 1)
        #expect(params[0]["workspaceId"] as? String == "ws-1")
        #expect(params[0]["fileName"] as? String == "doc.pdf")
        #expect(params[0]["data"] as? String == payload.base64EncodedString())
        #expect(params[0]["mimeType"] as? String == "application/pdf")
        #expect(!fake.didCallMethod("file.attachmentUpload.begin"))
        #expect(placed == AttachmentUploadService.PlacedAttachment(
            attachmentId: "att-1", fileName: "doc.pdf",
            path: ".intent/attachments/doc.pdf", size: 5,
            mimeType: "application/pdf", uploadedAt: "2026-08-27T00:00:00Z"))
    }

    @Test func nilMimeTypeIsOmittedFromParams() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["file.placeAttachment"] = Self.placementResponse(mimeType: nil)
        let service = AttachmentUploadService(connection: fake)

        let placed = try await service.placeData(
            workspaceId: "ws-1", fileName: "doc.pdf", data: Data([1, 2, 3]))

        let params = fake.paramsForMethod("file.placeAttachment")
        #expect(params[0]["mimeType"] == nil)
        #expect(placed.mimeType == nil)
    }

    @Test func smallFilePlacesSingleShotFromDiskBytes() async throws {
        let payload = Data("file bytes on disk".utf8)
        let url = try Self.tempFile(payload)
        let fake = FakeConnectionManager()
        fake.responseMap["file.placeAttachment"] = Self.placementResponse()
        let service = AttachmentUploadService(connection: fake)

        _ = try await service.placeFile(
            workspaceId: "ws-1", fileName: "doc.pdf", fileURL: url)

        let params = fake.paramsForMethod("file.placeAttachment")
        #expect(params.count == 1)
        #expect(params[0]["data"] as? String == payload.base64EncodedString())
    }

    @Test func malformedPlacementResponseThrows() async {
        let fake = FakeConnectionManager()
        fake.responseMap["file.placeAttachment"] = ["ok": true, "path": "p"]
        let service = AttachmentUploadService(connection: fake)

        await #expect(throws: UploadError.malformedResponse(method: "file.placeAttachment")) {
            _ = try await service.placeData(
                workspaceId: "ws-1", fileName: "doc.pdf", data: Data([1]))
        }
    }

    // MARK: - Chunked path

    @Test func dataAboveSingleShotCapUsesChunkedSession() async throws {
        let size = AttachmentUploadService.maxSingleShotBytes + 1
        var payload = Data(count: size)
        payload[0] = 0xAB
        payload[size - 1] = 0xCD
        let fake = FakeConnectionManager()
        fake.responseMap["file.attachmentUpload.begin"] = Self.beginResponse()
        fake.responseMap["file.attachmentUpload.chunk"] = ["uploadId": "up-1", "seq": 0, "receivedBytes": 1]
        fake.responseMap["file.attachmentUpload.commit"] = Self.placementResponse(size: size)
        let service = AttachmentUploadService(connection: fake)

        let placed = try await service.placeData(
            workspaceId: "ws-1", fileName: "big.bin", data: payload, mimeType: "application/octet-stream")

        #expect(!fake.didCallMethod("file.placeAttachment"))
        let begin = fake.paramsForMethod("file.attachmentUpload.begin")
        #expect(begin.count == 1)
        #expect(begin[0]["workspaceId"] as? String == "ws-1")
        #expect(begin[0]["fileName"] as? String == "big.bin")
        #expect(begin[0]["sizeBytes"] as? Int == size)
        #expect(begin[0]["mimeType"] as? String == "application/octet-stream")
        #expect(begin[0]["sha256"] as? String == AttachmentUploadService.sha256Hex(of: payload))
        // 25 MB + 1 at the 16 MiB chunk cap → exactly two chunks.
        let chunks = fake.paramsForMethod("file.attachmentUpload.chunk")
        #expect(chunks.count == 2)
        #expect(chunks[0]["seq"] as? Int == 0)
        #expect(chunks[1]["seq"] as? Int == 1)
        let first = Data(base64Encoded: chunks[0]["data"] as? String ?? "")
        let second = Data(base64Encoded: chunks[1]["data"] as? String ?? "")
        #expect(first?.count == AttachmentUploadService.uploadChunkBytes)
        #expect(second?.count == size - AttachmentUploadService.uploadChunkBytes)
        #expect((first ?? Data()) + (second ?? Data()) == payload)
        #expect(fake.paramsForMethod("file.attachmentUpload.commit").count == 1)
        #expect(placed.size == size)
    }

    @Test func chunkMathRespectsDaemonMaxChunkBytes() async throws {
        let payload = Data((0..<10).map { UInt8($0) })
        let fake = FakeConnectionManager()
        fake.responseMap["file.attachmentUpload.begin"] = Self.beginResponse(maxChunkBytes: 4)
        fake.responseMap["file.attachmentUpload.chunk"] = ["uploadId": "up-1", "seq": 0, "receivedBytes": 4]
        fake.responseMap["file.attachmentUpload.commit"] = Self.placementResponse(size: payload.count)
        var fractions: [Double] = []

        _ = try await AttachmentUploadService.placeChunked(
            connection: fake, workspaceId: "ws-1", fileName: "tiny.bin",
            mimeType: nil, size: payload.count,
            sha256: AttachmentUploadService.sha256Hex(of: payload),
            readChunk: { offset, length in
                payload.subdata(in: offset..<min(offset + length, payload.count))
            },
            onProgress: { fractions.append($0) })

        let chunks = fake.paramsForMethod("file.attachmentUpload.chunk")
        #expect(chunks.count == 3)
        #expect(chunks.map { $0["seq"] as? Int } == [0, 1, 2])
        #expect(chunks.map { $0["uploadId"] as? String } == ["up-1", "up-1", "up-1"])
        let slices = chunks.map { Data(base64Encoded: $0["data"] as? String ?? "") ?? Data() }
        #expect(slices == [Data([0, 1, 2, 3]), Data([4, 5, 6, 7]), Data([8, 9])])
        #expect(fractions == [1.0 / 3.0, 2.0 / 3.0, 1.0])
        let commit = fake.paramsForMethod("file.attachmentUpload.commit")
        #expect(commit.count == 1)
        #expect(commit[0]["uploadId"] as? String == "up-1")
    }

    @Test func largeFileStreamsChunksFromDisk() async throws {
        let size = AttachmentUploadService.maxSingleShotBytes + 3
        var payload = Data(count: size)
        payload[0] = 0x11
        payload[size - 1] = 0x22
        let url = try Self.tempFile(payload, name: "big.bin")
        let fake = FakeConnectionManager()
        fake.responseMap["file.attachmentUpload.begin"] = Self.beginResponse()
        fake.responseMap["file.attachmentUpload.chunk"] = ["uploadId": "up-1", "seq": 0, "receivedBytes": 1]
        fake.responseMap["file.attachmentUpload.commit"] = Self.placementResponse(size: size)
        let service = AttachmentUploadService(connection: fake)

        _ = try await service.placeFile(workspaceId: "ws-1", fileName: "big.bin", fileURL: url)

        #expect(!fake.didCallMethod("file.placeAttachment"))
        let begin = fake.paramsForMethod("file.attachmentUpload.begin")
        #expect(begin[0]["sizeBytes"] as? Int == size)
        #expect(begin[0]["sha256"] as? String == AttachmentUploadService.sha256Hex(of: payload))
        let chunks = fake.paramsForMethod("file.attachmentUpload.chunk")
        #expect(chunks.count == 2)
        let assembled = chunks.reduce(Data()) { acc, params in
            acc + (Data(base64Encoded: params["data"] as? String ?? "") ?? Data())
        }
        #expect(assembled == payload)
    }

    // MARK: - Abort on failure

    @Test func chunkFailureAbortsSessionBestEffort() async {
        let payload = Data((0..<10).map { UInt8($0) })
        let fake = FakeConnectionManager()
        fake.responseMap["file.attachmentUpload.begin"] = Self.beginResponse(uploadId: "up-9", maxChunkBytes: 4)
        fake.errorMap["file.attachmentUpload.chunk"] = NSError(domain: "test", code: -7)
        fake.responseMap["file.attachmentUpload.abort"] = ["uploadId": "up-9", "aborted": true]

        await #expect(throws: (any Error).self) {
            _ = try await AttachmentUploadService.placeChunked(
                connection: fake, workspaceId: "ws-1", fileName: "tiny.bin",
                mimeType: nil, size: payload.count,
                sha256: AttachmentUploadService.sha256Hex(of: payload),
                readChunk: { offset, length in
                    payload.subdata(in: offset..<min(offset + length, payload.count))
                },
                onProgress: nil)
        }

        #expect(!fake.didCallMethod("file.attachmentUpload.commit"))
        let abort = fake.paramsForMethod("file.attachmentUpload.abort")
        #expect(abort.count == 1)
        #expect(abort[0]["uploadId"] as? String == "up-9")
    }

    @Test func commitFailureAbortsAndRethrowsOriginalError() async {
        let payload = Data((0..<4).map { UInt8($0) })
        let fake = FakeConnectionManager()
        fake.responseMap["file.attachmentUpload.begin"] = Self.beginResponse(uploadId: "up-9", maxChunkBytes: 4)
        fake.responseMap["file.attachmentUpload.chunk"] = ["uploadId": "up-9", "seq": 0, "receivedBytes": 4]
        fake.errorMap["file.attachmentUpload.commit"] = NSError(domain: "test", code: -8)
        // Abort itself failing must not mask the original error.
        fake.errorMap["file.attachmentUpload.abort"] = NSError(domain: "test", code: -9)

        await #expect(throws: NSError(domain: "test", code: -8)) {
            _ = try await AttachmentUploadService.placeChunked(
                connection: fake, workspaceId: "ws-1", fileName: "tiny.bin",
                mimeType: nil, size: payload.count,
                sha256: AttachmentUploadService.sha256Hex(of: payload),
                readChunk: { offset, length in
                    payload.subdata(in: offset..<min(offset + length, payload.count))
                },
                onProgress: nil)
        }

        #expect(fake.paramsForMethod("file.attachmentUpload.abort").count == 1)
    }

    @Test func malformedBeginResponseThrowsWithoutAbort() async {
        let fake = FakeConnectionManager()
        fake.responseMap["file.attachmentUpload.begin"] = ["maxChunkBytes": 16]

        await #expect(throws: UploadError.malformedResponse(method: "file.attachmentUpload.begin")) {
            _ = try await AttachmentUploadService.placeChunked(
                connection: fake, workspaceId: "ws-1", fileName: "tiny.bin",
                mimeType: nil, size: 4, sha256: String(repeating: "a", count: 64),
                readChunk: { _, _ in Data() }, onProgress: nil)
        }

        #expect(!fake.didCallMethod("file.attachmentUpload.abort"))
    }

    // MARK: - SHA-256

    @Test func sha256MatchesKnownVector() throws {
        // NIST FIPS 180-2 test vector for "abc".
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let abc = Data("abc".utf8)
        #expect(AttachmentUploadService.sha256Hex(of: abc) == expected)
        let url = try Self.tempFile(abc, name: "abc.txt")
        #expect(try AttachmentUploadService.sha256Hex(fileURL: url) == expected)
    }

    @Test func streamingFileHashMatchesInMemoryHashAcrossBlocks() throws {
        // Larger than one hash block (1 MiB) so the streaming loop iterates.
        var payload = Data(count: AttachmentUploadService.hashBlockBytes * 2 + 5)
        payload[0] = 0x42
        payload[payload.count - 1] = 0x24
        let url = try Self.tempFile(payload)
        #expect(try AttachmentUploadService.sha256Hex(fileURL: url)
            == AttachmentUploadService.sha256Hex(of: payload))
    }

    // MARK: - 1 GiB cap

    @Test func overCapFileIsRejectedBeforeAnyRpc() async throws {
        // Sparse file: 1 GiB + 1 logical bytes without touching disk blocks.
        let url = try Self.tempFile(Data(), name: "huge.bin")
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(AttachmentUploadService.maxAttachmentBytes) + 1)
        try handle.close()
        let fake = FakeConnectionManager()
        let service = AttachmentUploadService(connection: fake)

        await #expect(throws: UploadError.payloadTooLarge(
            size: AttachmentUploadService.maxAttachmentBytes + 1)
        ) {
            _ = try await service.placeFile(
                workspaceId: "ws-1", fileName: "huge.bin", fileURL: url)
        }

        #expect(fake.requestLog.isEmpty)
    }

    @Test func missingFileIsRejectedBeforeAnyRpc() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).bin")
        let fake = FakeConnectionManager()
        let service = AttachmentUploadService(connection: fake)

        await #expect(throws: UploadError.unreadableFile) {
            _ = try await service.placeFile(
                workspaceId: "ws-1", fileName: "missing.bin", fileURL: missing)
        }

        #expect(fake.requestLog.isEmpty)
    }
}
