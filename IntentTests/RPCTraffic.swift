import Foundation

/// Compact UTF-8 JSON at the injectable connection boundary, not a socket capture.
/// Envelopes retain every payload field; only the transport-assigned RPC id is
/// normalized to 0. Key sorting removes ordering variance, and no WebSocket/TLS
/// framing is counted. Identifier strings in params/results are NOT stripped.
enum RPCFixtureJSON {
    static func encode(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }

    static func request(method: String, params: [String: Any]) throws -> Data {
        var envelope: [String: Any] = ["jsonrpc": "2.0", "id": 0, "method": method]
        if !params.isEmpty { envelope["params"] = params }
        return try encode(envelope)
    }

    static func response(_ result: Any) throws -> Data {
        try encode(["jsonrpc": "2.0", "id": 0, "result": result])
    }

    static func notification(method: String, params: Any) throws -> Data {
        try encode(["jsonrpc": "2.0", "method": method, "params": params])
    }
}

struct RPCMilestone {
    /// One monotonic order for starts, completions and inbound notifications.
    let order: Int
    let elapsed: Duration
    let connectionGeneration: Int
}

struct RecordedRPC {
    let method: String
    let params: [String: Any]
    let started: RPCMilestone
    let requestJSON: Data
    var completed: RPCMilestone?
    var responseJSON: Data?
    /// Local failures/cancellation have no received JSON frame. Never invent
    /// response bytes from an NSError's localized description.
    var failure: String?
}

struct RecordedRPCNotification {
    let method: String
    let params: Any
    let received: RPCMilestone
    let json: Data
}

struct RPCTraffic {
    let requests: [RecordedRPC]
    let notifications: [RecordedRPCNotification]

    var requestBytes: Int { requests.reduce(0) { $0 + $1.requestJSON.count } }
    var responseBytes: Int { requests.reduce(0) { $0 + ($1.responseJSON?.count ?? 0) } }
    var notificationBytes: Int { notifications.reduce(0) { $0 + $1.json.count } }
    var totalBytes: Int { requestBytes + responseBytes + notificationBytes }
    var pendingCount: Int { requests.filter { $0.completed == nil }.count }
    var failures: [String] { requests.compactMap(\.failure) }

    var summary: String {
        "requests=\(requests.count) requestBytes=\(requestBytes) responseBytes=\(responseBytes) "
            + "notificationBytes=\(notificationBytes) totalBytes=\(totalBytes) "
            + "pending=\(pendingCount) failures=\(failures.count)"
    }

    var methodCounts: [String: Int] {
        requests.reduce(into: [:]) { counts, request in counts[request.method, default: 0] += 1 }
    }

    func calls(_ method: String) -> [RecordedRPC] {
        requests.filter { $0.method == method }
    }
}
