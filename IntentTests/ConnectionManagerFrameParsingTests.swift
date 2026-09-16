import Foundation
@testable import Intent
import Testing

extension ConnectionManagerTests {
    @Test func parseInboundFrameResponseWithResult() throws {
        let responseID = 7
        let frame = ConnectionManager.parseInboundFrame("""
        {"jsonrpc":"2.0","id":7,"result":{"workspaces":[{"id":"ws-1"}]}}
        """)
        guard case let .response(id, result)? = frame else {
            Issue.record("Expected .response, got \(String(describing: frame))")
            return
        }
        #expect(id == responseID)
        let dictionary = try #require(result.value as? [String: Any])
        let workspaces = try #require(dictionary["workspaces"] as? [[String: Any]])
        #expect(workspaces.first?["id"] as? String == "ws-1")
        #expect(frame?.label == "id=7")
    }

    @Test func parseInboundFrameResponseWithoutResultFieldStillResolves() {
        let responseID = 8
        let frame = ConnectionManager.parseInboundFrame("""
        {"jsonrpc":"2.0","id":8}
        """)
        guard case let .response(id, result)? = frame else {
            Issue.record("Expected .response, got \(String(describing: frame))")
            return
        }
        #expect(id == responseID)
        #expect(result.value as? [String: Any] == nil)
    }

    @Test func parseInboundFrameErrorWithDataCodeAndDataMessage() {
        let responseID = 9
        let invalidParamsCode = -32_602
        let frame = ConnectionManager.parseInboundFrame("""
        {"jsonrpc":"2.0","id":9,"error":{"code":-32602,"message":"Invalid params",\
        "data":{"code":"not-found","message":"unknown agent id: gone"}}}
        """)
        guard case let .error(id, error)? = frame else {
            Issue.record("Expected .error, got \(String(describing: frame))")
            return
        }
        #expect(id == responseID)
        #expect(error.domain == "WebSocket")
        #expect(error.code == invalidParamsCode)
        #expect(error.intentErrorDataCode == "not-found")
        #expect(error.isEntityNotFound)
        #expect(error.localizedDescription == "unknown agent id: gone (-32602)")
        #expect(frame?.label == "id=9")
    }

    @Test func parseInboundFrameErrorWithoutDataOmitsDataCode() {
        let responseID = 10
        let invalidParamsCode = -32_602
        let frame = ConnectionManager.parseInboundFrame("""
        {"jsonrpc":"2.0","id":10,"error":{"code":-32602,"message":"unknown agent id: gone"}}
        """)
        guard case let .error(id, error)? = frame else {
            Issue.record("Expected .error, got \(String(describing: frame))")
            return
        }
        #expect(id == responseID)
        #expect(error.code == invalidParamsCode)
        #expect(error.intentErrorDataCode == nil)
        #expect(!error.isEntityNotFound)
        #expect(error.localizedDescription == "unknown agent id: gone (-32602)")
    }

    @Test func parseInboundFrameErrorWithoutCodeUsesFallbackAndPlainDescription() {
        let frame = ConnectionManager.parseInboundFrame("""
        {"jsonrpc":"2.0","id":11,"error":{"message":"boom"}}
        """)
        guard case let .error(_, error)? = frame else {
            Issue.record("Expected .error, got \(String(describing: frame))")
            return
        }
        #expect(error.code == -1)
        #expect(error.localizedDescription == "boom")
    }

    @Test func parseInboundFrameNotification() throws {
        let frame = ConnectionManager.parseInboundFrame("""
        {"jsonrpc":"2.0","method":"events.event",\
        "params":{"type":"workspace:updated","data":{"id":"ws-1"}}}
        """)
        guard case let .notification(method, params)? = frame else {
            Issue.record("Expected .notification, got \(String(describing: frame))")
            return
        }
        #expect(method == "events.event")
        let dictionary = try #require(params.value as? [String: Any])
        #expect(dictionary["type"] as? String == "workspace:updated")
        #expect(frame?.label == "method=events.event")
    }
}

extension ConnectionManagerTests {
    @Test func parseInboundFrameRejectsMalformedAndNonObjectInput() {
        #expect(ConnectionManager.parseInboundFrame("not valid json") == nil)
        #expect(ConnectionManager.parseInboundFrame("") == nil)
        #expect(ConnectionManager.parseInboundFrame("[1,2,3]") == nil)
        #expect(ConnectionManager.parseInboundFrame("\"a string\"") == nil)
        #expect(ConnectionManager.parseInboundFrame("{}") == nil)
        #expect(ConnectionManager.parseInboundFrame("{\"id\":\"abc\",\"result\":1}") == nil)
    }

    @Test func parseInboundFrameRunsOffMainActor() async {
        let responseID = 12
        let frame = await Task.detached {
            ConnectionManager.parseInboundFrame(
                "{\"jsonrpc\":\"2.0\",\"id\":12,\"result\":true}"
            )
        }.value
        guard case let .response(id, result)? = frame else {
            Issue.record("Expected .response, got \(String(describing: frame))")
            return
        }
        #expect(id == responseID)
        #expect(result.value as? Bool == true)
    }

    @Test func parseInboundFramePreDecodesChatPushOffMainActor() async throws {
        let expectedSequence = 3
        let frame = await Task.detached {
            ConnectionManager.parseInboundFrame("""
            {"jsonrpc":"2.0","method":"subscription.push","params":{
            "subscriptionId":"sub-chat","kind":"delta","seq":3,"delta":{
            "added":[{"messageId":"m-1","role":"assistant","block":{
            "type":"text","id":"m-1:0","text":"hi"},"streamingComplete":true}],
            "updated":[],"removedIds":[]}}}
            """)
        }.value
        guard case let .subscriptionPush(push)? = frame else {
            Issue.record("Expected .subscriptionPush, got \(String(describing: frame))")
            return
        }
        #expect(push.subscriptionId == "sub-chat")
        #expect(push.kind == .delta)
        #expect(push.seq == expectedSequence)
        let chatBlocks = try #require(push.delta?.chatBlocks)
        #expect(chatBlocks.count == 1)
        #expect(chatBlocks.first?.messageId == "m-1")
        #expect(chatBlocks.first?.block.resolvedText == "hi")
        #expect(chatBlocks.first?.streamingComplete == true)
        #expect(frame?.label == "method=subscription.push")
    }

    @Test func parseInboundFrameChatSnapshotPushRunsOffMainActor() async throws {
        let frame = await Task.detached {
            ConnectionManager.parseInboundFrame("""
            {"jsonrpc":"2.0","method":"subscription.push","params":{
            "subscriptionId":"sub-chat","kind":"snapshot","seq":0,"snapshot":{
            "agentId":"a","truncated":false,"totalMessages":1,"messages":[{
            "id":"m-1","role":"user","timestamp":"t","contentBlocks":[{
            "type":"text","id":"m-1:0","text":"Run the tests"}]}]}}}
            """)
        }.value
        guard case let .subscriptionPush(push)? = frame else {
            Issue.record("Expected .subscriptionPush, got \(String(describing: frame))")
            return
        }
        let messages = try #require(push.snapshotMessages)
        #expect(messages.map(\.id) == ["m-1"])
        #expect(messages.first?.contentBlocks?.first?.resolvedText == "Run the tests")
        #expect(push.snapshotMeta?["agentId"] as? String == "a")
    }

    @Test func parseInboundFrameMalformedPushStaysNotification() throws {
        let frame = ConnectionManager.parseInboundFrame("""
        {"jsonrpc":"2.0","method":"subscription.push",\
        "params":{"subscriptionId":"sub-1","kind":"snapshot","seq":0}}
        """)
        guard case let .notification(method, params)? = frame else {
            Issue.record("Expected .notification, got \(String(describing: frame))")
            return
        }
        #expect(method == "subscription.push")
        let dictionary = try #require(params.value as? [String: Any])
        #expect(dictionary["subscriptionId"] as? String == "sub-1")
    }

    @Test func slowFrameLogLineIncludesMainActorWaitInThresholdCheck() {
        let threshold = 0.05
        let waited = ConnectionManager.slowFrameLogLine(
            label: "method=subscription.push",
            byteCount: 512,
            parseElapsed: 0.002,
            waitElapsed: 0.4,
            dispatchElapsed: 0.001,
            threshold: threshold
        )
        #expect(
            waited
                == "[ConnectionManager] slow frame method=subscription.push "
                + "bytes=512 parse=2ms wait=400ms dispatch=1ms"
        )
        #expect(ConnectionManager.slowFrameLogLine(
            label: "id=1",
            byteCount: 10,
            parseElapsed: 0.2,
            waitElapsed: 0,
            dispatchElapsed: 0,
            threshold: threshold
        ) != nil)
        #expect(ConnectionManager.slowFrameLogLine(
            label: "id=1",
            byteCount: 10,
            parseElapsed: 0,
            waitElapsed: 0,
            dispatchElapsed: 0.2,
            threshold: threshold
        ) != nil)
        #expect(ConnectionManager.slowFrameLogLine(
            label: "id=1",
            byteCount: 10,
            parseElapsed: 0.01,
            waitElapsed: 0.01,
            dispatchElapsed: 0.01,
            threshold: threshold
        ) == nil)
    }
}
