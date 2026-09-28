import Foundation
import Testing

/// Explicit received error fixture. Local cancellations/errors have no JSON
/// response; a scripted daemon rejection does, and must stay in the ledger.
nonisolated struct RPCFixtureRejection: LocalizedError, CustomNSError {
    let code: Int
    let message: String
    var errorDescription: String? { message }
    static var errorDomain: String { "WebSocket" }
    var errorCode: Int { code }
    var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: message] }
    var json: [String: Any] { ["jsonrpc": "2.0", "id": 0, "error": ["code": code, "message": message]] }
}

enum ConversationBudgetEvidence {
    /// Opt-in artifact output from the SAME test body on native or portable
    /// runners. Contains every frame, including deferred completions/cleanup.
    /// Transport ids are already 0 in RPCTraffic; this is connection-boundary
    /// JSON, not a socket capture or a device first-paint measurement.
    static func emit(_ name: String, _ traffic: RPCTraffic) throws {
        guard let directory = ProcessInfo.processInfo.environment["STARTUP_BUDGET_DIRECTORY"] else { return }
        let requests: [[String: Any]] = try traffic.requests.map { request in
            var row: [String: Any] = [
                "method": request.method, "params": request.params,
                "start": request.started.order, "epoch": request.started.connectionGeneration,
                "elapsed": String(describing: request.started.elapsed),
                "request": try JSONSerialization.jsonObject(with: request.requestJSON)
            ]
            row["end"] = request.completed?.order
            row["completedElapsed"] = request.completed.map { String(describing: $0.elapsed) }
            row["failure"] = request.failure
            if let response = request.responseJSON {
                row["response"] = try JSONSerialization.jsonObject(with: response)
                row["responseBase64"] = response.base64EncodedString()
            }
            row["requestBase64"] = request.requestJSON.base64EncodedString()
            return row
        }
        let notifications: [[String: Any]] = try traffic.notifications.map { notification in
            [
                "order": notification.received.order, "epoch": notification.received.connectionGeneration,
                "elapsed": String(describing: notification.received.elapsed),
                "frame": try JSONSerialization.jsonObject(with: notification.json),
                "base64": notification.json.base64EncodedString()
            ]
        }
        let artifact: [String: Any] = [
            "fixture": "conversation-budget-v1", "name": name,
            "requests": requests, "notifications": notifications,
            "requestBytes": traffic.requestBytes, "responseBytes": traffic.responseBytes,
            "notificationBytes": traffic.notificationBytes, "totalBytes": traffic.totalBytes,
            "pending": traffic.pendingCount
        ]
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try RPCFixtureJSON.encode(artifact).write(to: root.appendingPathComponent(name + ".json"), options: .atomic)
    }
}
