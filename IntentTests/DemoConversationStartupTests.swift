import Foundation
@testable import Intent
import Testing

extension DemoFixturesTests {
    @Test func startupBarriersAreExplicitAndOnlyGateTheChosenAgentsReads() {
        let arguments = ["--demo-agent-detail-trigger-file=/tmp/metadata", "--demo-chat-snapshot-trigger-file=/tmp/snapshot"]
        let params = ["agentId": DemoFixtures.longConversationAgentId]
        #expect(DemoFixtures.startupResponseGate(for: "agent.get", params: params, arguments: []) == nil)
        #expect(DemoFixtures.startupResponseGate(for: "agent.get", params: params, arguments: arguments) == .triggerFile(URL(fileURLWithPath: "/tmp/metadata")))
        #expect(DemoFixtures.startupResponseGate(for: "chat.subscribe", params: params, arguments: arguments) == .triggerFile(URL(fileURLWithPath: "/tmp/snapshot")))
        #expect(DemoFixtures.startupResponseGate(for: "agent.getQueue", params: params, arguments: arguments) == nil)
        #expect(DemoFixtures.startupResponseGate(for: "agent.get", params: ["agentId": "another-agent"], arguments: arguments) == nil)
    }

    @Test func startupFixtureHasALongUnreadTailAndCanonicalWorkspace() throws {
        let rows = DemoFixtures.startupTranscriptMessages
        let ids = rows.compactMap { $0["id"] as? String }
        let marker = try #require(ids.firstIndex(of: DemoFixtures.startupSeenMessageId))
        #expect(ids.count - marker > 20)
        #expect(Set(ids).count == ids.count)
        let response = DemoFixtures.response(for: "agent.get", params: ["agentId": DemoFixtures.longConversationAgentId]) as? [String: Any]
        let agent = try #require(response?["agent"] as? [String: Any])
        #expect(agent["workspaceId"] as? String == DemoFixtures.longConversationWorkspaceId)
        #expect(!DemoFixtures.startupTranscriptRequested(by: []))
        #expect(DemoFixtures.startupTranscriptRequested(by: ["--demo-startup-transcript"]))
    }
}
