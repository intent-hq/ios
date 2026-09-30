import Combine
import Foundation

/// A single attempt owns a temporary destination socket and all staging IDs.
/// Cancellation never cancels a mutating RPC: its reply may hold an ID needed
/// for cleanup. Commit is an explicit point after which cancellation is refused.
@MainActor
final class WorkspaceTransferRelay {
    let workspaceId: String
    let source: any SessionConnectionManaging
    let target: any SessionConnectionManaging
    let timing: WorkspaceTransferTiming
    let update: (String, Double?, Bool) -> Void
    private var failure: Error?
    private var export: WorkspaceTransferExport?
    private var importId: String?
    private var importBeginSent = false
    private var commitSent = false
    private var committed = false
    private var observers: [AnyCancellable] = []
    private var preflightTask: Task<WorkspaceTransferPlan, Error>?

    init(
        workspaceId: String,
        source: any SessionConnectionManaging,
        target: any SessionConnectionManaging,
        timing: WorkspaceTransferTiming,
        update: @escaping (String, Double?, Bool) -> Void
    ) {
        self.workspaceId = workspaceId
        self.source = source
        self.target = target
        self.timing = timing
        self.update = update
    }

    func cancel() {
        guard !commitSent else { return }
        fail(CancellationError())
        preflightTask?.cancel()
    }

    /// A returned warning means import succeeded but source finalization failed.
    func run(destination: StoredConnection, archiveSource: Bool) async throws -> String? {
        guard source !== target else {
            throw WorkspaceTransferError.message("Choose a different machine for the transfer.")
        }
        defer {
            observers.removeAll()
            target.disconnect()
        }
        do {
            update("Checking the destination…", nil, true)
            observe(source, name: "source")
            let plan = try await preflight(destination)
            try check()
            let export = WorkspaceTransferExport(workspaceId: workspaceId, source: source, timing: timing) { [weak self] message in
                guard let self, !commitSent, failure == nil else { return }
                update(message, nil, true)
            }
            self.export = export
            update("Preparing the transfer…", nil, true)
            let archive = try await export.start()
            try check()
            guard archive.manifest["creatingIntentdVersion"] as? String == plan.manifest["creatingIntentdVersion"] as? String else {
                throw WorkspaceTransferError.message("The source version changed. Refresh the transfer preview and try again.")
            }
            try await stage(archive)
            try check()
            try await commit()
            let warning = await finalize(archiveSource: archiveSource)
            await export.dispose()
            return warning
        } catch {
            let cleanupWarning = await cleanup()
            await export?.dispose()
            if commitSent, !committed {
                throw WorkspaceTransferError.message(
                    "The destination did not confirm the transfer. It may already contain the workspace. Check it before trying again. The source was not archived."
                    + " " + error.localizedDescription + cleanupWarning
                )
            }
            if !cleanupWarning.isEmpty {
                throw WorkspaceTransferError.message(error.localizedDescription + cleanupWarning)
            }
            throw failure ?? error
        }
    }

    private func commit() async throws {
        commitSent = true
        update("Finishing the transfer on the destination…", 1, false)
        let result = try await target.request("workspace.import.commit", params: ["importId": try requireImportId()], timeout: timing.commit) as? [String: Any]
        guard let workspace = result?["workspace"] as? [String: Any], workspace["id"] as? String == workspaceId else {
            throw WorkspaceTransferError.message("The destination returned an invalid completion response.")
        }
        committed = true
        importId = nil
    }

    private func preflight(_ destination: StoredConnection) async throws -> WorkspaceTransferPlan {
        let task = Task { try await validate(destination) }
        preflightTask = task
        let timer = Task { [weak self, timing] in
            do {
                try await timing.sleep(.seconds(timing.preflight))
                try Task.checkCancellation()
                self?.fail(WorkspaceTransferError.message("The destination took too long to connect. Check the machine and try again."))
                task.cancel()
            } catch { return }
        }
        defer {
            timer.cancel()
            preflightTask = nil
        }
        return try await task.value
    }

    private func validate(_ destination: StoredConnection) async throws -> WorkspaceTransferPlan {
        try check()
        guard try await source.confirmedPrincipal().isOwner, destination.principal?.isOwner != false else {
            throw WorkspaceTransferError.message("Workspace transfer requires owner access on both machines.")
        }
        let response = try await source.request("workspace.transfer.plan", params: ["workspaceId": workspaceId], timeout: timing.request)
        let plan = try WorkspaceTransferPlan(response: response, workspaceId: workspaceId)
        try check()
        let server = destination.server
        try await target.connect(
            hosts: server.hosts,
            port: server.port,
            token: destination.token,
            certFingerprint: server.certFingerprint,
            tcAddress: server.tcAddress
        )
        try check()
        observe(target, name: "destination")
        let principal = try await target.confirmedPrincipal()
        guard principal.isOwner else {
            throw WorkspaceTransferError.message("Workspace transfer requires owner access on the destination.")
        }
        if let saved = destination.principal, !ConnectionPrincipal.samePerson(saved.id, principal.id) {
            throw WorkspaceTransferError.message("The destination identity changed. Pair with that machine again.")
        }
        let status = try await target.request("system.status", params: [:], timeout: timing.request) as? [String: Any]
        guard let version = status?["version"] as? String,
              version == plan.manifest["creatingIntentdVersion"] as? String else {
            throw WorkspaceTransferError.message("Both machines must run the same host version. Update them before transferring.")
        }
        let listed = try await target.request("workspace.list", params: ["includeArchived": true], timeout: timing.request) as? [String: Any]
        guard let rows = listed?["workspaces"] as? [[String: Any]] else {
            throw WorkspaceTransferError.message("The destination could not check for an existing workspace.")
        }
        guard !rows.contains(where: { $0["id"] as? String == workspaceId }) else {
            throw WorkspaceTransferError.message("This workspace already exists on that machine. Choose another destination.")
        }
        try check()
        return plan
    }

    private func stage(_ archive: WorkspaceTransferArchive) async throws {
        importBeginSent = true
        let result = try await target.request(
            "workspace.import.begin",
            params: ["manifest": archive.manifest, "archiveSizeBytes": archive.size, "archiveSha256": archive.sha256],
            timeout: timing.request
        ) as? [String: Any]
        importId = try WorkspaceTransferWire.identifier(result?["importId"])
        guard let limit = WorkspaceTransferWire.integer(result?["maxChunkBytes"]), limit >= archive.chunkBytes else {
            throw WorkspaceTransferError.message("The destination cannot receive this archive's transfer chunks. Update both hosts.")
        }
        let importId = try requireImportId()
        var received: Int64 = 0
        for sequence in 0..<archive.totalChunks {
            try check()
            let response = try await source.request(
                "workspace.export.read",
                params: ["workspaceId": workspaceId, "exportId": archive.exportId, "seq": sequence],
                timeout: timing.chunk
            )
            let chunk = try validatedChunk(response, archive: archive, sequence: sequence, received: received)
            try check()
            let receipt = try await target.request(
                "workspace.import.chunk",
                params: ["importId": importId, "seq": sequence, "data": chunk.encoded],
                timeout: timing.chunk
            ) as? [String: Any]
            received += Int64(chunk.count)
            guard receipt?["importId"] as? String == importId,
                  WorkspaceTransferWire.integer(receipt?["seq"]) == Int64(sequence),
                  WorkspaceTransferWire.integer(receipt?["receivedBytes"]) == received else {
                throw WorkspaceTransferError.message("The destination did not confirm receipt of the transfer archive.")
            }
            try check()
            update("Transferring workspace…", Double(received) / Double(archive.size), true)
        }
        guard received == archive.size else {
            throw WorkspaceTransferError.message("The transfer archive was incomplete. Try again.")
        }
    }

    private func validatedChunk(
        _ response: Any, archive: WorkspaceTransferArchive, sequence: Int, received: Int64
    ) throws -> (encoded: String, count: Int) {
        let maximumEncoded = ((archive.chunkBytes + WorkspaceTransferWire.decodedQuantum - 1)
            / WorkspaceTransferWire.decodedQuantum) * WorkspaceTransferWire.base64Quantum
        guard let row = response as? [String: Any], row["exportId"] as? String == archive.exportId,
              WorkspaceTransferWire.integer(row["seq"]) == Int64(sequence),
              WorkspaceTransferWire.integer(row["totalChunks"]) == Int64(archive.totalChunks),
              let encoded = row["data"] as? String, encoded.utf8.count <= maximumEncoded,
              let bytes = Data(base64Encoded: encoded), !bytes.isEmpty,
              Int64(bytes.count) == min(Int64(archive.chunkBytes), archive.size - received) else {
            throw WorkspaceTransferError.message("The source returned an invalid archive chunk. Try again.")
        }
        return (encoded, bytes.count)
    }

    private func finalize(archiveSource: Bool) async -> String? {
        update("Settling the source workspace…", 1, false)
        do {
            let exportId = try WorkspaceTransferWire.identifier(export?.exportId)
            let result = try await source.request(
                "workspace.export.finalize",
                params: ["workspaceId": workspaceId, "exportId": exportId, "archiveSource": archiveSource],
                timeout: timing.request
            ) as? [String: Any]
            guard result?["exportId"] as? String == exportId, ConnectionPrincipal.boolean(result?["finalized"]) == true else {
                throw WorkspaceTransferError.message("The source did not confirm finalization.")
            }
            return nil
        } catch {
            let cleanupWarning = await cleanup()
            return "The workspace was transferred successfully. The source could not be finalized; check its archive status on the source machine. Do not repeat the transfer. "
                + error.localizedDescription + cleanupWarning
        }
    }

    private func cleanup() async -> String {
        var failures: [String] = []
        if let importId, !committed {
            do {
                _ = try await target.request("workspace.import.abort", params: ["importId": importId], timeout: timing.cleanup)
            } catch { failures.append("destination") }
        }
        if let exportId = export?.exportId {
            do {
                _ = try await source.request(
                    "workspace.export.abort",
                    params: ["workspaceId": workspaceId, "exportId": exportId],
                    timeout: timing.cleanup
                )
            } catch { failures.append("source") }
        }
        if export?.didSendStart == true, export?.exportId == nil { failures.append("source") }
        if importBeginSent, importId == nil, !committed { failures.append("destination") }
        return failures.isEmpty ? "" : " Transfer cleanup could not be confirmed on the \(failures.joined(separator: " and "))."
    }

    private func requireImportId() throws -> String { try WorkspaceTransferWire.identifier(importId) }

    private func check() throws {
        if let failure { throw failure }
        try Task.checkCancellation()
    }

    private func fail(_ error: Error) {
        if failure == nil { failure = error }
        export?.stop(with: error)
    }

    private func observe(_ connection: any SessionConnectionManaging, name: String) {
        observers.append(connection.connectionStatePublisher.sink { [weak self] state in
            if state != .connected {
                self?.fail(WorkspaceTransferError.message("The \(name) disconnected during transfer. Reconnect and check the workspace."))
            }
        })
    }
}
