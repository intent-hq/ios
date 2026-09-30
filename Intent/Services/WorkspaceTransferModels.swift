import Foundation

struct WorkspaceTransferPlan {
    let estimatedBytes: Int64
    let warnings: [String]
    let manifest: [String: Any]

    init(response: Any, workspaceId: String) throws {
        guard let result = response as? [String: Any], let plan = result["plan"] as? [String: Any],
              let manifest = plan["manifest"] as? [String: Any],
              manifest["workspaceId"] as? String == workspaceId,
              let version = manifest["creatingIntentdVersion"] as? String, !version.isEmpty,
              let bytes = WorkspaceTransferWire.integer(plan["totalSizeBytes"]),
              let warnings = plan["warnings"] as? [[String: Any]] else {
            throw WorkspaceTransferError.message("The host could not provide a transfer preview. Update the host and try again.")
        }
        self.manifest = manifest
        estimatedBytes = bytes
        self.warnings = warnings.compactMap { $0["message"] as? String }
    }
}

enum WorkspaceTransferError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message): message
        }
    }
}

enum WorkspaceTransferWire {
    static let bytesPerKiB = 1024
    static let maximumChunkMiB = 16
    static let maximumChunkBytes = maximumChunkMiB * bytesPerKiB * bytesPerKiB
    static let base64Quantum = 4
    static let decodedQuantum = 3
    static let sha256Length = 64
    static let hexadecimalDigits = Set("0123456789abcdefABCDEF".utf8)

    static func integer(_ value: Any?) -> Int64? {
        guard let number = ConnectionPrincipal.number(value), number >= 0 else { return nil }
        return Int64(exactly: number)
    }

    static func identifier(_ value: Any?) throws -> String {
        guard let value = value as? String, !value.isEmpty else {
            throw WorkspaceTransferError.message("The host returned an invalid transfer response.")
        }
        return value
    }
}

struct WorkspaceTransferArchive {
    let exportId: String
    let manifest: [String: Any]
    let size: Int64
    let sha256: String
    let chunkBytes: Int
    let totalChunks: Int

    init(data: [String: Any], workspaceId: String, exportId: String) throws {
        guard data["workspaceId"] as? String == workspaceId, data["exportId"] as? String == exportId,
              let manifest = data["manifest"] as? [String: Any], manifest["workspaceId"] as? String == workspaceId,
              let size = WorkspaceTransferWire.integer(data["archiveSizeBytes"]), size > 0,
              let chunkBytes = WorkspaceTransferWire.integer(data["maxChunkBytes"]),
              chunkBytes > 0, chunkBytes <= WorkspaceTransferWire.maximumChunkBytes,
              let totalChunks = WorkspaceTransferWire.integer(data["totalChunks"]),
              totalChunks == (size - 1) / chunkBytes + 1,
              let sha256 = data["archiveSha256"] as? String,
              sha256.count == WorkspaceTransferWire.sha256Length,
              sha256.utf8.allSatisfy({ WorkspaceTransferWire.hexadecimalDigits.contains($0) }) else {
            throw WorkspaceTransferError.message("The source returned an invalid transfer archive.")
        }
        self.exportId = exportId
        self.manifest = manifest
        self.size = size
        self.sha256 = sha256
        self.chunkBytes = Int(chunkBytes)
        self.totalChunks = Int(totalChunks)
    }
}

@MainActor
struct WorkspaceTransferTiming {
    var preflight: TimeInterval = 15
    var request: TimeInterval = 30
    var build: TimeInterval = 600
    var chunk: TimeInterval = 120
    var commit: TimeInterval = 600
    var cleanup: TimeInterval = 10
    var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
}
