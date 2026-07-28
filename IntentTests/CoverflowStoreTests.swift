import Foundation
import Testing
@testable import Intent

@Suite("CoverflowStore agent:idle waiting handling")
@MainActor
struct CoverflowStoreTests {

    // Fixtures deliberately omit workspaceId so the handler's re-fetch paths
    // (network calls via ConnectionManager) stay out of these unit tests.
    private func idleEvent(agentId: String, data: [String: Any]) -> [String: Any] {
        ["type": "agent:idle", "agentId": agentId, "data": data]
    }

    private func streamEvent(agentId: String) -> [String: Any] {
        ["type": "agent:stream:delta", "agentId": agentId]
    }

    @Test func idleWithWaitingFlagShowsStars() {
        let store = CoverflowStore(forTesting: true)
        store.handleEvent(idleEvent(agentId: "a", data: ["isWaitingForOtherAgents": true]))
        #expect(store.isAgentStreaming("a") == true)
        #expect(store.unreviewedAgentIds.isEmpty)
    }

    @Test func idleWhileWaitingDoesNotMarkUnreviewed() {
        let store = CoverflowStore(forTesting: true)
        store.handleEvent(streamEvent(agentId: "a"))
        store.handleEvent(idleEvent(agentId: "a", data: ["isWaitingForOtherAgents": true]))
        #expect(store.isAgentStreaming("a") == true)
        #expect(!store.unreviewedAgentIds.contains("a"))
    }

    @Test func idleWithoutFlagMarksUnreviewedAndClearsStars() {
        let store = CoverflowStore(forTesting: true)
        store.handleEvent(streamEvent(agentId: "a"))
        store.handleEvent(idleEvent(agentId: "a", data: ["isBackground": false]))
        #expect(store.isAgentStreaming("a") == false)
        #expect(store.unreviewedAgentIds.contains("a"))
    }

    @Test func idleWithFalseFlagClearsPreviousWaiting() {
        let store = CoverflowStore(forTesting: true)
        store.handleEvent(idleEvent(agentId: "a", data: ["isWaitingForOtherAgents": true]))
        #expect(store.isAgentStreaming("a") == true)
        store.handleEvent(idleEvent(agentId: "a", data: ["isWaitingForOtherAgents": false]))
        #expect(store.isAgentStreaming("a") == false)
    }

    @Test func legacyFieldNameIsIgnored() {
        // The daemon emits isWaitingForOtherAgents; the old isWaitingForAgents
        // key was never emitted and must not be honored.
        let store = CoverflowStore(forTesting: true)
        store.handleEvent(streamEvent(agentId: "a"))
        store.handleEvent(idleEvent(agentId: "a", data: ["isWaitingForAgents": true]))
        #expect(store.isAgentStreaming("a") == false)
        #expect(store.unreviewedAgentIds.contains("a"))
    }

    @Test func wrappedEventEnvelopeIsUnwrapped() {
        let store = CoverflowStore(forTesting: true)
        let wrapped: [String: Any] = [
            "subscriptionId": "sub-1",
            "event": idleEvent(agentId: "a", data: ["isWaitingForOtherAgents": true]),
        ]
        store.handleEvent(wrapped)
        #expect(store.isAgentStreaming("a") == true)
    }
}
