import Foundation
@testable import Intent
import Testing

@MainActor
enum WorkspaceStatusTestSupport {
    private static let hookDelayMs = 10_000
    private static let prNumber = 123
    static let workspace = ConversationStartupFixture.workspaceId

    static func hook(_ id: String = "hook-1", agentId: String = ConversationStartupFixture.parentId) -> [String: Any] {
        [
            "hookId": id, "workspaceId": workspace, "agentId": agentId, "name": "Check build",
            "code": "return { dispatch: false };", "state": "scheduled", "delayMs": hookDelayMs,
            "createdAt": "2026-09-27T12:00:00Z"
        ]
    }

    static func monitor(_ id: String = "monitor-1", agentId: String = ConversationStartupFixture.parentId) -> [String: Any] {
        [
            "monitorId": id, "workspaceId": workspace, "agentId": agentId, "repo": "intent-hq/ios",
            "prNumber": prNumber, "state": "active", "pendingChanges": ["A new comment"], "hasPendingChanges": true
        ]
    }

    static func seedRows(_ fixture: ConversationStartupFixture) {
        fixture.connection.responseMap["hook.list"] = ["hooks": [hook()]]
        fixture.connection.responseMap["prMonitor.list"] = ["monitors": [monitor()]]
    }

    static func event(_ fixture: ConversationStartupFixture, type: String, id: String, extra: [String: Any] = [:]) {
        var data = extra
        data[type.hasPrefix("hook:") ? "hookId" : "monitorId"] = id
        data["workspaceId"] = workspace
        fixture.connection.deliverEvent(method: "events.event", params: [
            "type": type, "workspaceId": workspace, "data": data
        ])
    }

    static func acknowledgedIDs(_ connection: RPCRecordingConnection) throws -> Set<String> {
        try Set(connection.traffic().calls("events.subscribe").compactMap { request in
            guard let bytes = request.responseJSON else { return nil }
            let response = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            return (response?["result"] as? [String: Any])?["subscriptionId"] as? String
        })
    }

    static func waitForCleanup(_ connection: RPCRecordingConnection, events: Set<String>, chats: Int) async throws {
        try await waitUntil("all status and chat releases completed") {
            let traffic = connection.traffic()
            return traffic.calls("events.unsubscribe").count == events.count
                && traffic.calls("chat.unsubscribe").count == chats && traffic.pendingCount == 0
        }
        let ids = connection.paramsForMethod("events.unsubscribe").compactMap { $0["subscriptionId"] as? String }
        #expect(Set(ids) == events)
        #expect(ids.count == events.count)
    }
}
