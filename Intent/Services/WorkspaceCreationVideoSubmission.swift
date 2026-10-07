import Foundation
import Observation

/// Holds the first message until every video is uploaded. Retained by the draft
/// across dismissal/failure, including the server's workspace and agent identity.
@MainActor
@Observable final class WorkspaceCreationVideoSubmission {
    enum SubmissionError: LocalizedError, Equatable {
        case invalidCreationResponse, unconfirmed, busy

        var errorDescription: String? {
            switch self {
            case .invalidCreationResponse:
                "Could not read the new workspace or its initial agent. Your draft is saved. Retry to recover the same workspace."
            case .unconfirmed:
                "The workspace exists, but delivery of the first message is unconfirmed. Your draft is saved. Check status before sending again."
            case .busy:
                "This workspace submission is still in progress."
            }
        }
    }

    private(set) var workspace: Workspace?
    private(set) var isSubmitting = false
    private(set) var isUploading = false
    private let connection: ConnectionManagerRouting
    private let createParams: [String: Any]
    private let content: String
    private let imageBlocks: [[String: Any]]
    private let videos: [PendingFile]
    private let pipeline: ConversationAttachmentPipeline
    private let conversation: ConversationStore
    private var agentId: String?
    private var placed: [UUID: [[String: Any]]] = [:]
    private var messageId: String?

    var needsStatusCheck: Bool { attempt?.status == .unconfirmed }
    var uploadProgress: Double {
        guard !videos.isEmpty else { return 0 }
        return (Double(placed.count) + pipeline.fileUploadProgress.values.reduce(0, +)) / Double(videos.count)
    }
    private var attempt: ConversationSendAttempt? {
        conversation.sendAttempts.first { $0.id == messageId }
    }

    init(
        connection: ConnectionManagerRouting,
        params: [String: Any],
        videos: [PendingFile]
    ) throws {
        // Preflight the complete prompt/images before any workspace is created.
        try WorkspaceCreationImages.validateRequest(params)
        var params = params
        var initialAgent = params["initialAgent"] as? [String: Any] ?? [:]
        content = initialAgent.removeValue(forKey: "prompt") as? String ?? ""
        imageBlocks = initialAgent.removeValue(forKey: "imageBlocks") as? [[String: Any]] ?? []
        params["initialAgent"] = initialAgent
        createParams = params
        self.videos = videos
        self.connection = connection
        pipeline = ConversationAttachmentPipeline(uploadService: AttachmentUploadService(connection: connection))
        conversation = ConversationStore(connectionManager: connection)
    }

    func submit() async throws -> Workspace {
        guard !isSubmitting else { throw SubmissionError.busy }
        isSubmitting = true
        defer { isSubmitting = false }
        try Task.checkCancellation()
        if workspace == nil { try await createIdleWorkspace() }
        guard let workspace, let agentId else { throw SubmissionError.invalidCreationResponse }
        if messageId == nil {
            let blocks = try await uploadVideos(workspaceId: workspace.id)
            try Task.checkCancellation()
            let id = conversation.beginSendAttempt(agentId: agentId, content: content, workspaceId: workspace.id)
            conversation.prepareSendAttempt(id, imagePayload: .inline(imageBlocks), filePayload: .attachments(blocks))
            messageId = id
        }
        guard let messageId else { throw SubmissionError.unconfirmed }
        // Ordinary sends are NOT idempotent. Reuse the composer's recovery owner:
        // a lost reply may only be checked, never blindly resent (protocol §5.5).
        if needsStatusCheck { await conversation.inspectSendAttempt(messageId) }
        if attempt?.status == .preparing || attempt?.canRetry == true {
            do {
                try await conversation.sendPreparedAttempt(messageId)
            } catch {
                if needsStatusCheck { throw SubmissionError.unconfirmed }
                throw error
            }
        }
        guard attempt?.status.isConfirmed == true else { throw SubmissionError.unconfirmed }
        return workspace
    }

    private func createIdleWorkspace() async throws {
        try pipeline.validateVideos(in: videos, workspaceId: "")
        let result = try await connection.request(
            "workspace.create", params: createParams, timeout: CreateWorkspaceView.createRequestTimeout
        )
        guard let response = result as? [String: Any],
              let row = response["workspace"] as? [String: Any],
              let workspace = WorkspaceStore.parseWorkspace(row),
              let agent = response["initialAgent"] as? [String: Any],
              let id = agent["id"] as? String, !id.isEmpty else {
            throw SubmissionError.invalidCreationResponse
        }
        self.workspace = workspace
        agentId = id
    }

    private func uploadVideos(workspaceId: String) async throws -> [[String: Any]] {
        try pipeline.validateVideos(in: videos, workspaceId: workspaceId)
        isUploading = true
        defer { isUploading = false }
        for video in videos where placed[video.id] == nil {
            try Task.checkCancellation()
            do {
                if case let .attachments(blocks) = try await pipeline.buildFileBlocks(from: [video], workspaceId: workspaceId) {
                    placed[video.id] = blocks
                }
            } catch {
                throw NSError(domain: "WorkspaceCreation", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "The workspace was created, but a video could not be uploaded. Your prompt and attachments are saved. Retry to finish. \(error.localizedDescription)"
                ])
            }
        }
        return videos.flatMap { placed[$0.id] ?? [] }
    }
}
