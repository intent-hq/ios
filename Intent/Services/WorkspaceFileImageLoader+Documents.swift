import Foundation

extension WorkspaceFileImageLoader {
    static func cost(of media: WorkspaceFileMedia) -> Int {
        switch media {
        case .image(let image): decodedCost(of: image)
        case .video(let video): decodedCost(of: video.poster)
        case .pdf(let pdf): decodedCost(of: pdf.thumbnail)
        case .text(let file): file.byteCount * 2
        }
    }

    func video(workspaceId: String, path: String, mimeType: String? = nil) async throws -> WorkspaceVideo {
        let key = "video\u{0}" + Self.fileKey(workspaceId: workspaceId, path: path)
        let media = try await cachedMedia(key: key) { [chunkRequester] in
            .video(try await Self.fetchVideo(
                chunkRequester: chunkRequester,
                workspaceId: workspaceId,
                path: path,
                mimeType: mimeType,
                limit: ImportedPhotoVideo.maxBytes
            ))
        }
        guard case .video(let video) = media else { throw LoadError.notAVideo }
        return video
    }

    /// Stream videos to disk on the global executor; only one decoded chunk is
    /// held in memory. Image and saved-asset assembly keep their smaller cap.
    @concurrent
    nonisolated private static func fetchVideo(
        chunkRequester: ChunkRequester, workspaceId: String, path: String, mimeType: String?, limit: Int
    ) async throws -> WorkspaceVideo {
        let url = try WorkspaceVideo.temporaryURL(path: path, mimeType: mimeType)
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: url) } }
        try Data().write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let byteCount = try await writeFileBytes(
            chunkRequester: chunkRequester, workspaceId: workspaceId, path: path, to: handle, limit: limit
        )
        try handle.close()
        let video = try await WorkspaceVideo.prepare(fileURL: url, byteCount: byteCount)
        retained = true
        return video
    }

    func text(workspaceId: String, path: String) async throws -> WorkspaceTextFile {
        let key = "text\u{0}" + Self.fileKey(workspaceId: workspaceId, path: path)
        let media = try await cachedMedia(key: key) { [chunkRequester] in
            .text(try await WorkspaceTextFile.load(path: path) { handle in
                try await Self.writeFileBytes(
                    chunkRequester: chunkRequester,
                    workspaceId: workspaceId,
                    path: path,
                    to: handle,
                    limit: WorkspaceTextFile.maxBytes,
                    length: Self.pdfChunkLength
                )
            })
        }
        guard case .text(let file) = media else { throw LoadError.notUTF8Text }
        return file
    }

    func pdf(workspaceId: String, path: String) async throws -> WorkspacePDF {
        let key = "pdf\u{0}" + Self.fileKey(workspaceId: workspaceId, path: path)
        let media = try await cachedMedia(key: key) { [chunkRequester, diagnostics] in
            let owner = DiagnosticRequestContext.Owner(operation: .pdfLoad, site: .attachmentPipeline, recording: .deferred)
            do {
                return try await DiagnosticRequestContext.$owner.withValue(owner) {
                    .pdf(try await Self.fetchPDF(chunkRequester: chunkRequester, workspaceId: workspaceId, path: path))
                }
            } catch {
                Self.recordPDFFailure(error, store: diagnostics)
                throw error
            }
        }
        guard case .pdf(let pdf) = media else { throw LoadError.notAPDF }
        return pdf
    }

    /// Closed categories only: never persist a workspace, filename, URL or
    /// foreign error description. One record per fetch, not per cached failure.
    nonisolated private static func recordPDFFailure(_ error: any Error, store: DiagnosticStore) {
        var failure = DiagnosticErrorOwnership.failure(for: error)
        var stage: DiagnosticEvent.Stage = .request
        if let error = error as? LoadError {
            let classification: DiagnosticFailure.Classification
            switch error {
            case .fileTooLarge: classification = .tooLarge
            case .malformedResponse: classification = .malformedResponse
            case .pdfPasswordRequired: classification = .passwordRequired
            case .notAPDF: classification = .unreadable
            default: classification = .unknown
            }
            stage = error == .notAPDF || error == .pdfPasswordRequired ? .decode : .response
            failure = DiagnosticFailure(origin: .localOperation, classification: classification)
        } else if failure.origin == .unknown {
            stage = .read
        }
        DiagnosticErrorOwnership.record(
            error,
            event: DiagnosticEvent(
                kind: .operationFailed,
                operation: .pdfLoad,
                site: .attachmentPipeline,
                stage: stage,
                outcome: .failed,
                failure: failure,
                effect: failure.origin == .remoteRPC ? .remoteRejected : .unknown
            ),
            store: store
        )
    }

    @concurrent
    nonisolated private static func fetchPDF(
        chunkRequester: ChunkRequester, workspaceId: String, path: String
    ) async throws -> WorkspacePDF {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-pdf-\(UUID()).pdf")
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: url) } }
        try Data().write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let byteCount = try await writeFileBytes(
            chunkRequester: chunkRequester,
            workspaceId: workspaceId,
            path: path,
            to: handle,
            limit: WorkspacePDF.maxBytes,
            length: pdfChunkLength
        )
        try handle.close()
        let pdf = try await WorkspacePDF.prepare(
            fileURL: url, name: URL(fileURLWithPath: path).lastPathComponent, byteCount: byteCount
        )
        retained = true
        return pdf
    }
}
