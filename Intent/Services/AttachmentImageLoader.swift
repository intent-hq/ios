import Foundation
import UIKit

/// Loads attachment-reference image blocks (`{ type: "image", attachmentId }`
/// with no inline `data`, PROTOCOL §5.5): resolves the attachment-registry
/// row to its workspace-relative path via `file.getAttachmentInfo` (§5.9),
/// then fetches and decodes the bytes through `WorkspaceFileImageLoader`
/// (`file.readChunk`). Attachment rows are immutable (id → path never
/// changes), so resolved paths cache for the session; resolution failures
/// are NOT cached — a transient daemon error may succeed on the next render
/// pass (FE parity: attachment-image-url.ts).
@MainActor
final class AttachmentImageLoader {
    static let shared = AttachmentImageLoader()

    enum LoadError: Error, Equatable {
        /// The `file.getAttachmentInfo` response was missing required fields.
        case malformedResponse
        /// The registry row exists but its file was deleted out-of-band
        /// (`exists: false` — the row survives the delete, PROTOCOL §5.9).
        case fileMissing
    }

    private let connection: ConnectionManagerRouting
    private let fileLoader: WorkspaceFileImageLoader
    /// Session cache of resolved workspace-relative paths, keyed by
    /// (workspaceId, attachmentId). Intentionally uncapped (ios#264): it
    /// grows only with distinct attachments the transcript actually
    /// rendered, at ~280 B per entry measured by
    /// `SessionCacheBoundsMeasurementTests`, so even a 10k-attachment
    /// session retains ~2.7 MiB; evicting would only re-run an immutable
    /// `file.getAttachmentInfo` resolution.
    private(set) var pathCache: [String: String] = [:]
    /// In-flight resolutions, so concurrent requests for the same
    /// attachment share one `file.getAttachmentInfo` round-trip.
    private var inFlight: [String: Task<String, Error>] = [:]

    init(
        connection: ConnectionManagerRouting = ConnectionManager.shared,
        fileLoader: WorkspaceFileImageLoader = .shared
    ) {
        self.connection = connection
        self.fileLoader = fileLoader
    }

    /// Resolved-and-fetched image for an attachment-reference block.
    func image(workspaceId: String, attachmentId: String) async throws -> UIImage {
        let path = try await resolvePath(workspaceId: workspaceId, attachmentId: attachmentId)
        return try await fileLoader.image(workspaceId: workspaceId, path: path)
    }

    /// User-initiated retry: clears the byte-fetch negative cache for the
    /// resolved path (if known) so the fetch actually re-runs, then loads
    /// again. Path resolution failures were never cached, so they retry
    /// naturally.
    func retryImage(workspaceId: String, attachmentId: String) async throws -> UIImage {
        if let path = pathCache[Self.key(workspaceId, attachmentId)] {
            fileLoader.forgetFailure(workspaceId: workspaceId, path: path)
        }
        return try await image(workspaceId: workspaceId, attachmentId: attachmentId)
    }

    private static func key(_ workspaceId: String, _ attachmentId: String) -> String {
        "\(workspaceId)\u{0}\(attachmentId)"
    }

    /// Cached-or-fetched workspace-relative path for an attachment id.
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
                "file.getAttachmentInfo", params: ["attachmentId": attachmentId])
            guard let dict = result as? [String: Any],
                  let path = dict["path"] as? String,
                  let exists = dict["exists"] as? Bool
            else { throw LoadError.malformedResponse }
            guard exists else { throw LoadError.fileMissing }
            // Cache inside the task so an early-cancelled awaiter (view
            // scrolled away) doesn't lose the completed resolution.
            self.pathCache[key] = path
            return path
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}
