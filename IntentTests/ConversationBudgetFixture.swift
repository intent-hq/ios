import Foundation
@testable import Intent
import Testing

/// Valid persisted wire rows shared with the desktop source replay. Existing
/// lifecycle fixtures deliberately keep their own distinct registration ids.
@MainActor
final class ConversationBudgetFixture {
    let startup = ConversationStartupFixture()
    var connection: RPCRecordingConnection { startup.connection }
    var rows = 1
    var largeBlocks = false
    private let fullToolBytes = 900_000
    private let fullImageBytes = 2_000_000
    private var registration = 100

    init() {
        let inherited = connection.responseForRequest
        connection.responseForRequest = { [weak self] method, params in
            guard let self else { return nil }
            switch method {
            case "chat.subscribe":
                registration += 1
                let id = "ios-budget-chat-\(registration)"
                let agentId = params["agentId"] as? String ?? ConversationStartupFixture.parentId
                var metadata: [String: Any] = [
                    "agentId": agentId, "totalMessages": rows, "truncated": false,
                    "nextToken": NSNull(), "isResponding": false, "turnInFlight": false
                ]
                if params["deltaEncoding"] as? String == "incremental" {
                    metadata["deltaEncoding"] = "incremental"
                }
                connection.stubChatSnapshot(subscriptionId: id, messages: messages(agentId), meta: metadata)
                return ["subscriptionId": id]
            case "agent.getConversation":
                return ["messages": [], "truncated": false, "totalMessages": rows, "nextToken": NSNull()]
            default:
                return inherited?(method, params)
            }
        }
    }

    func messages(_ agentId: String) -> [[String: Any]] {
        (0..<rows).map { index in
            var blocks: [[String: Any]] = [["id": "text-\(index)", "type": "text", "text": "Ready café 🦊 \(index)"]]
            if largeBlocks {
                blocks += [
                    [
                        "id": "tool-\(index)", "type": "tool_result", "tool_use_id": "call-\(index)",
                        "output": "bounded preview", "outputTruncated": true, "outputBytes": fullToolBytes
                    ],
                    [
                        "id": "image-\(index)", "type": "image", "mimeType": "image/png",
                        "dataTruncated": true, "dataBytes": fullImageBytes
                    ]
                ]
            }
            return [
                "id": "budget-message-\(index)", "agentId": agentId, "role": "user", "seq": index,
                "timestamp": "2026-09-28T00:00:00.000Z", "contentBlocks": blocks
            ]
        }
    }

    func warmWorkspace() async {
        startup.session.retainWorkspaceStatus(workspaceId: ConversationStartupFixture.workspaceId, consumer: UUID())
        await startup.session.hooksStore.load(workspaceId: ConversationStartupFixture.workspaceId)
        await startup.session.prMonitorsStore.seed(workspaceId: ConversationStartupFixture.workspaceId)
    }

    func primeCatalogs() async {
        startup.providerId = "auggie"
        startup.modelId = "fixture-model"
        startup.parentMetadata["specialist"] = "fixture-specialist"
        connection.responseMap["models.list"] = [
            "providerId": "auggie", "models": [["id": "fixture-model", "name": "Fixture model", "provider": "auggie"]]
        ]
        connection.responseMap["specialist.list"] = [
            "specialists": [["id": "fixture-specialist", "name": "Fixture specialist"]]
        ]
        await startup.options.ensureSpecialists()
        await startup.options.ensureModels(providerId: "auggie")
    }

    func stopAndWait() async throws {
        let registrations = connection.traffic().calls("chat.subscribe").filter { $0.failure == nil }.count
        startup.stop()
        try await waitUntil("budget fixture cleanup") {
            let traffic = self.connection.traffic()
            return traffic.pendingCount == 0 && traffic.calls("chat.unsubscribe").count == registrations
                && traffic.calls("events.unsubscribe").count == 2
        }
    }
}
