import CryptoKit
import Foundation

/// Places chat-attachment payloads into a workspace's attachment registry via
/// the daemon (`file.placeAttachment` + `file.attachmentUpload.*`, PROTOCOL
/// §5.9), mirroring cloudlands-fe's attachment placement: the single-shot
/// `data` arm up to 25 MB, the staged chunked session (`begin` → sequential
/// `chunk`s → `commit`) above that, up to the daemon's 1 GiB cap. File
/// payloads stream off disk via `FileHandle`, so a 1 GiB attachment is never
/// loaded into memory at once.
@MainActor
final class AttachmentUploadService {
    static let shared = AttachmentUploadService()

    /// A successful placement — the daemon's `file.placeAttachment` result
    /// (`file.attachmentUpload.commit` is byte-shape-identical). The registry
    /// fields `mimeType`/`uploadedAt` are additive (v6.12) and presence-detected.
    struct PlacedAttachment: Equatable, Sendable {
        let attachmentId: String
        let fileName: String
        /// Workspace-relative path under `.intent/attachments/`.
        let path: String
        /// Placed byte length.
        let size: Int
        let mimeType: String?
        let uploadedAt: String?
    }

    enum UploadError: Error, Equatable {
        /// Payload exceeds the daemon's 1 GiB per-attachment cap (checked
        /// client-side before any RPC).
        case payloadTooLarge(size: Int)
        /// A daemon response was missing required fields.
        case malformedResponse(method: String)
        /// The file's size could not be determined.
        case unreadableFile
    }

    // Keep MiB/GiB and minute conversions visible in these named protocol limits.
    // swiftlint:disable no_magic_numbers
    /// Single-shot `data`-arm cap: base64 inflates ~4/3 and the serialized
    /// JSON-RPC frame is capped at 40 MiB (PROTOCOL §1.3) — matches
    /// cloudlands-fe's `MAX_REMOTE_ATTACHMENT_BYTES`.
    nonisolated static let maxSingleShotBytes = 25 * 1024 * 1024
    /// The daemon's per-attachment byte cap (`file.attachmentUpload.begin`
    /// rejects declared sizes above 1 GiB, PROTOCOL §5.9).
    nonisolated static let maxAttachmentBytes = 1024 * 1024 * 1024
    /// Raw bytes per upload chunk — the daemon's 16 MiB decoded-slice cap;
    /// the effective size is min(this, `begin`'s `maxChunkBytes`).
    nonisolated static let uploadChunkBytes = 16 * 1024 * 1024
    /// Bytes read per block during the streaming SHA-256 pass.
    nonisolated static let hashBlockBytes = 1024 * 1024
    /// Per-call timeout for placement, chunk sends, and commit: a 16 MiB
    /// chunk is ~21 MiB of base64 on the wire, and commit reassembles and
    /// SHA-256-verifies up to 1 GiB before replying — mirrors cloudlands-fe's
    /// `UPLOAD_TRANSFER_TIMEOUT_MS`.
    nonisolated static let transferTimeout: TimeInterval = 5 * 60
    // swiftlint:enable no_magic_numbers

    /// Fraction (0–1) of chunks acknowledged by the daemon. Only the chunked
    /// path reports progress.
    typealias ProgressCallback = @MainActor (Double) -> Void

    struct ChunkedPlacementMetadata {
        let workspaceId: String
        let fileName: String
        let mimeType: String?
        let size: Int
        let sha256: String
    }

    private struct UploadSession: Sendable {
        let uploadId: String
        let maxChunkBytes: Int
    }

    nonisolated private struct PlacementContext {
        let rpcClient: RPCClient
        let workspaceId: String
        let fileName: String
        let mimeType: String?
    }

    nonisolated private struct ChunkedPlacement {
        let context: PlacementContext
        let size: Int
        let sha256: String
    }

    @MainActor
    private final class RPCClient {
        let connection: ConnectionManagerRouting

        init(connection: ConnectionManagerRouting) {
            self.connection = connection
        }

        func placeAttachment(
            workspaceId: String,
            fileName: String,
            encodedData: String,
            mimeType: String?
        ) async throws -> PlacedAttachment {
            var params: [String: Any] = [
                "workspaceId": workspaceId,
                "fileName": fileName,
                "data": encodedData
            ]
            if let mimeType, !mimeType.isEmpty { params["mimeType"] = mimeType }
            let result = try await connection.request(
                "file.placeAttachment",
                params: params,
                timeout: transferTimeout
            )
            return try parsePlacement(result, method: "file.placeAttachment")
        }

        func begin(
            workspaceId: String,
            fileName: String,
            mimeType: String?,
            size: Int,
            sha256: String
        ) async throws -> UploadSession {
            var params: [String: Any] = [
                "workspaceId": workspaceId,
                "fileName": fileName,
                "sizeBytes": size,
                "sha256": sha256
            ]
            if let mimeType, !mimeType.isEmpty { params["mimeType"] = mimeType }
            let result = try await connection.request(
                "file.attachmentUpload.begin",
                params: params,
                timeout: transferTimeout
            )
            guard let dict = result as? [String: Any],
                  let uploadId = dict["uploadId"] as? String,
                  let maxChunkBytes = dict["maxChunkBytes"] as? Int,
                  maxChunkBytes > 0
            else { throw UploadError.malformedResponse(method: "file.attachmentUpload.begin") }
            return UploadSession(uploadId: uploadId, maxChunkBytes: maxChunkBytes)
        }

        func uploadChunk(uploadId: String, sequence: Int, encodedData: String) async throws {
            _ = try await connection.request(
                "file.attachmentUpload.chunk",
                params: [
                    "uploadId": uploadId,
                    "seq": sequence,
                    "data": encodedData
                ],
                timeout: transferTimeout
            )
        }

        func commit(uploadId: String) async throws -> PlacedAttachment {
            let result = try await connection.request(
                "file.attachmentUpload.commit",
                params: ["uploadId": uploadId],
                timeout: transferTimeout
            )
            return try parsePlacement(result, method: "file.attachmentUpload.commit")
        }

        func abort(uploadId: String) async {
            _ = try? await connection.request(
                "file.attachmentUpload.abort",
                params: ["uploadId": uploadId],
                timeout: transferTimeout
            )
        }
    }

    private let rpcClient: RPCClient

    init(connection: ConnectionManagerRouting = ConnectionManager.shared) {
        rpcClient = RPCClient(connection: connection)
    }
}

extension AttachmentUploadService {
    /// Place an in-memory payload (e.g. a picked or pasted image).
    func placeData(
        workspaceId: String,
        fileName: String,
        data: Data,
        mimeType: String? = nil,
        onProgress: ProgressCallback? = nil
    ) async throws -> PlacedAttachment {
        try await Self.place(
            context: PlacementContext(
                rpcClient: rpcClient,
                workspaceId: workspaceId,
                fileName: fileName,
                mimeType: mimeType
            ),
            data: data,
            onProgress: onProgress
        )
    }

    /// Place a file payload, streaming chunks off disk via `FileHandle` on
    /// the chunked path. Photos videos force this path at every size.
    func placeFile(
        workspaceId: String,
        fileName: String,
        fileURL: URL,
        mimeType: String? = nil,
        forceChunked: Bool = false,
        onProgress: ProgressCallback? = nil
    ) async throws -> PlacedAttachment {
        try await Self.placeFromFile(
            context: PlacementContext(
                rpcClient: rpcClient,
                workspaceId: workspaceId,
                fileName: fileName,
                mimeType: mimeType
            ),
            fileURL: fileURL,
            forceChunked: forceChunked,
            onProgress: onProgress
        )
    }

    // MARK: - Placement (nonisolated: hashing and disk reads stay off the
    // main actor; only the RPCs hop — same pattern as WorkspaceFileImageLoader)

    @concurrent
    nonisolated private static func place(
        context: PlacementContext,
        data: Data,
        onProgress: ProgressCallback?
    ) async throws -> PlacedAttachment {
        guard data.count <= maxAttachmentBytes else {
            throw UploadError.payloadTooLarge(size: data.count)
        }
        if data.count <= maxSingleShotBytes {
            return try await placeSingleShot(
                context: context,
                data: data
            )
        }
        return try await placeChunked(
            ChunkedPlacement(
                context: context,
                size: data.count,
                sha256: sha256Hex(of: data)
            ),
            readChunk: { offset, length in
                data.subdata(in: offset..<min(offset + length, data.count))
            },
            onProgress: onProgress
        )
    }

    @concurrent
    nonisolated private static func placeFromFile(
        context: PlacementContext,
        fileURL: URL,
        forceChunked: Bool,
        onProgress: ProgressCallback?
    ) async throws -> PlacedAttachment {
        let size = try fileSize(of: fileURL)
        guard size <= maxAttachmentBytes else {
            throw UploadError.payloadTooLarge(size: size)
        }
        if !forceChunked, size <= maxSingleShotBytes {
            let data = try Data(contentsOf: fileURL)
            return try await placeSingleShot(
                context: context,
                data: data
            )
        }
        let sha256 = try sha256Hex(fileURL: fileURL)
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        return try await placeChunked(
            ChunkedPlacement(
                context: context,
                size: size,
                sha256: sha256
            ),
            readChunk: { offset, length in
                try handle.seek(toOffset: UInt64(offset))
                // read(upToCount:) may legally return fewer bytes than
                // requested before EOF — accumulate until the full chunk
                // (or EOF) so a short read can't stage fewer bytes than
                // declared and fail the commit's size check.
                var chunk = Data(capacity: length)
                while chunk.count < length,
                      let piece = try handle.read(upToCount: length - chunk.count),
                      !piece.isEmpty {
                    chunk.append(piece)
                }
                return chunk
            },
            onProgress: onProgress
        )
    }

    nonisolated private static func placeSingleShot(
        context: PlacementContext,
        data: Data
    ) async throws -> PlacedAttachment {
        try await context.rpcClient.placeAttachment(
            workspaceId: context.workspaceId,
            fileName: context.fileName,
            encodedData: data.base64EncodedString(),
            mimeType: context.mimeType
        )
    }

    /// Chunked placement: `begin` (declares size + SHA-256), sequential
    /// `chunk` sends bounded by the daemon-returned `maxChunkBytes`, then
    /// `commit`. Any failure after `begin` aborts the session (best-effort —
    /// abort is idempotent and the daemon sweeps orphans) and rethrows.
    /// Internal for test visibility (lets tests exercise the chunk math with
    /// small payloads).
    static func placeChunked(
        connection: ConnectionManagerRouting,
        metadata: ChunkedPlacementMetadata,
        readChunk: @Sendable (_ offset: Int, _ length: Int) throws -> Data,
        onProgress: ProgressCallback?
    ) async throws -> PlacedAttachment {
        try await placeChunked(
            ChunkedPlacement(
                context: PlacementContext(
                    rpcClient: RPCClient(connection: connection),
                    workspaceId: metadata.workspaceId,
                    fileName: metadata.fileName,
                    mimeType: metadata.mimeType
                ),
                size: metadata.size,
                sha256: metadata.sha256
            ),
            readChunk: readChunk,
            onProgress: onProgress
        )
    }

    @concurrent
    nonisolated private static func placeChunked(
        _ placement: ChunkedPlacement,
        readChunk: @Sendable (_ offset: Int, _ length: Int) throws -> Data,
        onProgress: ProgressCallback?
    ) async throws -> PlacedAttachment {
        let session = try await placement.context.rpcClient.begin(
            workspaceId: placement.context.workspaceId,
            fileName: placement.context.fileName,
            mimeType: placement.context.mimeType,
            size: placement.size,
            sha256: placement.sha256
        )

        let chunkBytes = min(uploadChunkBytes, session.maxChunkBytes)
        let totalChunks = (placement.size + chunkBytes - 1) / chunkBytes
        do {
            for seq in 0..<totalChunks {
                let chunk = try readChunk(seq * chunkBytes, chunkBytes)
                try await placement.context.rpcClient.uploadChunk(
                    uploadId: session.uploadId,
                    sequence: seq,
                    encodedData: chunk.base64EncodedString()
                )
                if let onProgress {
                    await onProgress(Double(seq + 1) / Double(totalChunks))
                }
            }
            return try await placement.context.rpcClient.commit(uploadId: session.uploadId)
        } catch {
            // Best-effort: the daemon sweeps orphaned sessions on the next begin.
            await placement.context.rpcClient.abort(uploadId: session.uploadId)
            throw error
        }
    }

    nonisolated private static func parsePlacement(
        _ result: Any,
        method: String
    ) throws -> PlacedAttachment {
        guard let dict = result as? [String: Any],
              let attachmentId = dict["attachmentId"] as? String,
              let fileName = dict["fileName"] as? String,
              let path = dict["path"] as? String,
              let size = dict["size"] as? Int
        else { throw UploadError.malformedResponse(method: method) }
        return PlacedAttachment(
            attachmentId: attachmentId,
            fileName: fileName,
            path: path,
            size: size,
            mimeType: dict["mimeType"] as? String,
            uploadedAt: dict["uploadedAt"] as? String
        )
    }

    // MARK: - Hashing & file metadata

    /// Lowercase-hex SHA-256 of an in-memory payload.
    nonisolated static func sha256Hex(of data: Data) -> String {
        hexString(SHA256.hash(data: data))
    }

    /// Lowercase-hex SHA-256 of a file, streamed in bounded blocks.
    nonisolated static func sha256Hex(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: hashBlockBytes), !block.isEmpty {
            hasher.update(data: block)
        }
        return hexString(hasher.finalize())
    }

    nonisolated private static func hexString(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func fileSize(of url: URL) throws -> Int {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
            throw UploadError.unreadableFile
        }
        return size
    }
}
