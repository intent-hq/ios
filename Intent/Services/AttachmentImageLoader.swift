import Foundation
import UIKit

@MainActor
final class AttachmentImageLoader {
    static let shared = AttachmentImageLoader()

    enum LoadError: Error, Equatable {
        case malformedResponse
        case fileMissing
    }

    private let connection: ConnectionManagerRouting
    private let fileLoader: WorkspaceFileImageLoader
    private(set) var pathCache: [String: String] = [:]
    private var inFlight: [String: Task<String, Error>] = [:]

    init(
        connection: ConnectionManagerRouting = ConnectionManager.shared,
        fileLoader: WorkspaceFileImageLoader = .shared
    ) {
        self.connection = connection
        self.fileLoader = fileLoader
    }

    func image(workspaceId: String, attachmentId: String) async throws -> UIImage {
        let path = try await resolvePath(workspaceId: workspaceId, attachmentId: attachmentId)
        return try await fileLoader.image(workspaceId: workspaceId, path: path)
    }

    func retryImage(workspaceId: String, attachmentId: String) async throws -> UIImage {
        if let path = pathCache[Self.key(workspaceId, attachmentId)] {
            fileLoader.forgetFailure(workspaceId: workspaceId, path: path)
        }
        return try await image(workspaceId: workspaceId, attachmentId: attachmentId)
    }

    func video(workspaceId: String, attachmentId: String, mimeType: String? = nil) async throws -> WorkspaceVideo {
        let path = try await resolvePath(workspaceId: workspaceId, attachmentId: attachmentId)
        return try await fileLoader.video(workspaceId: workspaceId, path: path, mimeType: mimeType)
    }

    func retryVideo(workspaceId: String, attachmentId: String, mimeType: String? = nil) async throws -> WorkspaceVideo {
        if let path = pathCache[Self.key(workspaceId, attachmentId)] {
            fileLoader.forgetFailure(workspaceId: workspaceId, path: path)
        }
        return try await video(workspaceId: workspaceId, attachmentId: attachmentId, mimeType: mimeType)
    }

    private static func key(_ workspaceId: String, _ attachmentId: String) -> String {
        "\(workspaceId)\u{0}\(attachmentId)"
    }

    private func resolvePath(workspaceId: String, attachmentId: String) async throws -> String {
        let key = Self.key(workspaceId, attachmentId)
        if let cached = pathCache[key] {
            return cached
        }
        if let task = inFlight[key] {
            return try await task.value
        }
        let task = Task<String, Error> {
            let result = try await self.connection.request(
                "file.getAttachmentInfo",
                params: ["attachmentId": attachmentId]
            )
            guard let dict = result as? [String: Any],
                  let path = dict["path"] as? String,
                  let exists = dict["exists"] as? Bool
            else { throw LoadError.malformedResponse }
            guard exists else { throw LoadError.fileMissing }
            self.pathCache[key] = path
            return path
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}
