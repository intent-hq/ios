import Foundation
@testable import Intent

@MainActor
final class WorkspaceTransferConnection: FakeConnectionManager {
    var beforeRequest: ((String, [String: Any]) -> Void)?

    override func request(
        _ method: String, params: [String: Any] = [:], timeout: TimeInterval = ConnectionManager.defaultRequestTimeout
    ) async throws -> Any {
        beforeRequest?(method, params)
        return try await super.request(method, params: params, timeout: timeout)
    }
}

@MainActor
final class WorkspaceTransferFixture {
    static let chunkBytes = 1024
    static let version = "1.2.3"
    let source = WorkspaceTransferConnection()
    let target = WorkspaceTransferConnection()
    let payload = Data("archive".utf8)
    let store: WorkspaceTransferStore
    var destination = StoredConnection(
        server: PairedServer(hosts: ["target.local"], port: 7777, name: "Target", pairedAt: .distantPast,
                             certFingerprint: "target-pin", tcAddress: "tc-target"),
        token: "target-token"
    )
    var trace: [String] = []
    var sendsReadyBeforeReply = true

    var manifest: [String: Any] {
        ["workspaceId": "workspace", "creatingIntentdVersion": Self.version, "formatVersion": 2]
    }

    var ready: [String: Any] {
        [
            "workspaceId": "workspace", "exportId": "export", "manifest": manifest,
            "archiveSizeBytes": payload.count, "archiveSha256": String(repeating: "a", count: WorkspaceTransferWire.sha256Length),
            "maxChunkBytes": Self.chunkBytes, "totalChunks": 1
        ]
    }

    var startReply: [String: Any] { ["exportId": "export", "maxChunkBytes": Self.chunkBytes] }
    var beginReply: [String: Any] { ["importId": "import", "maxChunkBytes": Self.chunkBytes] }
    var commitReply: [String: Any] { ["workspace": ["id": "workspace"], "interruptedAgents": [String]()] }

    init(timing: WorkspaceTransferTiming = WorkspaceTransferTiming()) {
        let source = self.source
        let target = self.target
        store = WorkspaceTransferStore(workspaceId: "workspace", source: source, makeDestination: { target }, timing: timing)
        source.connectionState = .connected
        source.responseMap["workspace.transfer.plan"] = ["plan": [
            "manifest": manifest, "totalSizeBytes": payload.count,
            "warnings": [["code": "agents-running", "message": "Running agents will stop."]]
        ]]
        source.responseMap["events.subscribe"] = ["subscriptionId": "subscription"]
        source.responseMap["events.unsubscribe"] = ["unsubscribed": true]
        source.responseMap["workspace.export.start"] = startReply
        source.responseMap["workspace.export.read"] = [
            "exportId": "export", "seq": 0, "totalChunks": 1, "data": payload.base64EncodedString()
        ]
        source.responseMap["workspace.export.abort"] = ["aborted": true]
        source.responseMap["workspace.export.finalize"] = ["exportId": "export", "finalized": true]
        target.responseMap["system.status"] = ["version": Self.version]
        target.responseMap["workspace.list"] = ["workspaces": [[String: Any]]()]
        target.responseMap["workspace.import.begin"] = beginReply
        target.responseMap["workspace.import.chunk"] = ["importId": "import", "seq": 0, "receivedBytes": payload.count]
        target.responseMap["workspace.import.commit"] = commitReply
        target.responseMap["workspace.import.abort"] = ["aborted": true]
        source.beforeRequest = { [weak self] method, _ in
            self?.trace.append("source:" + method)
            if method == "workspace.export.start", self?.sendsReadyBeforeReply == true { self?.emitReady() }
        }
        target.beforeRequest = { [weak self] method, _ in self?.trace.append("target:" + method) }
    }

    func emitReady(_ data: [String: Any]? = nil) {
        emit(type: "workspace:transfer:ready", data: data ?? ready)
    }

    func emit(type: String, data: [String: Any]) {
        source.deliverEvent(method: "events.event", params: ["event": ["type": type, "data": data]])
    }

    func run(archiveSource: Bool = false) async {
        await store.loadPlan()
        await store.transfer(to: destination, archiveSource: archiveSource)
    }

    func start(archiveSource: Bool = false) async -> Task<Void, Never> {
        await store.loadPlan()
        return Task { await self.store.transfer(to: self.destination, archiveSource: archiveSource) }
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "transfer-test", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
