import Foundation
@testable import Intent
import Testing

@MainActor
struct ConversationStreamingFixtureTests {
    @Test(arguments: [false, true])
    func fullTraceConvergesToAuthorityWithoutEagerHydration(startsWithPartial: Bool) async throws {
        let fixture = ConversationStreamingFixture(startsWithPartial: startsWithPartial)
        let connection = RPCRecordingConnection()
        let store = await subscribedStore(connection)
        defer { store.reset() }
        for frame in fixture.frames(encoding: .full) {
            try connection.deliverNotification(params: frame)
        }
        let expected = try #require(ConversationMessage.parseMessage(fixture.authoritativeMessage))
        let actual = try #require(store.messages.first)
        #expect(actual.id == expected.id && actual.timestamp == expected.timestamp)
        #expect(actual.contentBlocks == expected.contentBlocks)
        #expect(!store.isStreaming && actual.isStreaming == false)
        #expect(actual.contentBlocks.last?.outputTruncation == .truncated)
        let traffic = connection.traffic()
        #expect(traffic.methodCounts == ["chat.subscribe": 1])
        #expect(traffic.notifications.count == fixture.fragments.count + 3)
        #expect(traffic.pendingCount == 0 && traffic.failures.isEmpty)
        #expect(traffic.notificationBytes == (try fixture.frames(encoding: .full).reduce(0) { total, frame in
            try total + RPCFixtureJSON.notification(method: "subscription.push", params: frame).count
        }))
    }

    @Test(arguments: [false, true], [false, true])
    func incrementalTraceAppendsEveryGrowthFrame(startsWithPartial: Bool, raw: Bool) async throws {
        let fixture = ConversationStreamingFixture(startsWithPartial: startsWithPartial)
        let connection = RPCRecordingConnection()
        let store = await subscribedStore(connection)
        defer { store.reset() }
        try connection.deliverNotification(params: fixture.snapshot(encoding: .incremental))
        var text = fixture.textPrefix
        var thinking = fixture.thinkingPrefix
        for (index, frame) in fixture.growth(encoding: .incremental).enumerated() {
            let push = try #require(SubscriptionPush.parse(method: "subscription.push", params: frame))
            let delta = try #require(push.delta)
            let wire = try #require((delta.added + delta.updated).first?["block"] as? [String: Any])
            #expect(wire["textDelta"] != nil && wire["text"] == nil)
            if raw {
                connection.deliverSubscriptionPush(SubscriptionPush(
                    subscriptionId: push.subscriptionId,
                    seq: push.seq,
                    delta: .init(added: delta.added, updated: delta.updated, removedIds: delta.removedIds)
                ))
            } else {
                try connection.deliverNotification(params: frame)
            }
            text += fixture.fragments[index]
            thinking += fixture.fragments[index]
            #expect(store.messages.first?.contentBlocks.first?.resolvedText == text)
            #expect(store.messages.first?.contentBlocks.first { $0.type == .thinking }?.resolvedText == thinking)
            #expect(store.isStreaming)
        }
        try connection.deliverNotification(params: fixture.toolFrame)
        try connection.deliverNotification(params: fixture.terminal)
        let expected = try #require(ConversationMessage.parseMessage(fixture.authoritativeMessage))
        #expect(store.messages.first?.contentBlocks == expected.contentBlocks)
        #expect(!store.isStreaming)
        #expect(connection.traffic().methodCounts == ["chat.subscribe": 1])
        #expect(try connection.traffic().notificationBytes == notificationBytes(fixture.frames(encoding: .incremental)))
    }

    @Test func matchedIncrementalTraceHasLinearFragmentBytesAndFullTerminal() throws {
        let fragments = Array(repeating: String(repeating: "🦊", count: 32), count: 8)
        let fixture = ConversationStreamingFixture(fragments: fragments)
        let full = try notificationBytes(fixture.growth(encoding: .full))
        let incremental = try notificationBytes(fixture.growth(encoding: .incremental))
        #expect(incremental < full)
        let doubled = ConversationStreamingFixture(fragments: fragments + fragments)
        // Variable-width seq numbers are the only growth beyond doubling
        // these equal-size fragment envelopes (seq 10 through 16).
        #expect(try notificationBytes(doubled.growth(encoding: .incremental)) == 2 * incremental + 7)
        let incrementalFrames = fixture.frames(encoding: .incremental)
        let fullFrames = fixture.frames(encoding: .full)
        let incrementalTerminal = try #require(incrementalFrames.last)
        let fullTerminal = try #require(fullFrames.last)
        #expect(try RPCFixtureJSON.encode(incrementalTerminal) == RPCFixtureJSON.encode(fullTerminal))
        let legacy = try #require(fixture.snapshot(encoding: .incremental, echoEncoding: false)["snapshot"] as? [String: Any])
        #expect(legacy["deltaEncoding"] == nil)
    }

    private func subscribedStore(_ connection: RPCRecordingConnection) async -> ConversationStore {
        connection.responseMap["chat.subscribe"] = ["subscriptionId": ConversationStreamingFixture.subscriptionId]
        connection.responseMap["chat.unsubscribe"] = [:] as [String: Any]
        let store = ConversationStore(connectionManager: connection)
        await store.subscribeLiveChat(agentId: ConversationStreamingFixture.agentId, workspaceId: "fixture-workspace")
        return store
    }

    private func notificationBytes(_ frames: [[String: Any]]) throws -> Int {
        try frames.reduce(0) { try $0 + RPCFixtureJSON.notification(method: "subscription.push", params: $1).count }
    }
}
