import Foundation
@testable import Intent
import Testing

@MainActor
struct RPCRecordingConnectionTests {
    @Test func capturesUTF8BytesOncePerFrameAndRetainsParameters() async throws {
        let connection = RPCRecordingConnection()
        connection.simulateConnect()
        connection.responseMap["echo"] = ["text": "café 🦊"]
        _ = try await connection.request("echo", params: ["text": "café 🦊"])
        var deliveries = 0
        connection.onEvent { _, _ in deliveries += 1 }
        connection.onEvent { _, _ in deliveries += 1 }
        try connection.deliverNotification(params: ["text": "café 🦊"], method: "event")
        let traffic = connection.traffic()
        let request = try #require(traffic.requests.first)
        let expectedRequest = #"{"id":0,"jsonrpc":"2.0","method":"echo","params":{"text":"café 🦊"}}"#
        let expectedResponse = #"{"id":0,"jsonrpc":"2.0","result":{"text":"café 🦊"}}"#
        let expectedNotification = #"{"jsonrpc":"2.0","method":"event","params":{"text":"café 🦊"}}"#
        #expect(request.params["text"] as? String == "café 🦊")
        #expect(request.requestJSON == Data(expectedRequest.utf8))
        #expect(request.responseJSON == Data(expectedResponse.utf8))
        #expect(traffic.requestBytes == expectedRequest.utf8.count)
        #expect(traffic.responseBytes == expectedResponse.utf8.count)
        #expect(traffic.notificationBytes == expectedNotification.utf8.count)
        #expect(traffic.totalBytes == expectedRequest.utf8.count + expectedResponse.utf8.count + expectedNotification.utf8.count)
        #expect(expectedRequest.utf8.count > expectedRequest.count)
        #expect(traffic.notifications.count == 1 && deliveries == 2)
    }

    @Test func recordsStartOrderCompletionOrderAndCrossGenerationResponses() async throws {
        let connection = RPCRecordingConnection()
        connection.simulateConnect()
        connection.pendingMethods = ["slow"]
        connection.responseMap["fast"] = ["ok": true]
        let slow = Task { _ = try await connection.request("slow", params: ["agentId": "parent"]) }
        defer { slow.cancel() }
        try await connection.waitForPendingRequests("slow")
        _ = try await connection.request("fast")
        #expect(connection.traffic().pendingCount == 1)
        connection.simulateConnect()
        #expect(connection.connectionGeneration == 1, "repeated connected is not a new connection")
        connection.simulateDisconnect()
        connection.simulateConnect()
        connection.resolvePending("slow", with: ["ok": true])
        try await slow.value
        let traffic = connection.traffic()
        let first = try #require(traffic.calls("slow").first)
        let second = try #require(traffic.calls("fast").first)
        #expect(first.started.order < second.started.order)
        #expect(try #require(second.completed).order < #require(first.completed).order)
        #expect(first.started.connectionGeneration == 1)
        #expect(first.completed?.connectionGeneration == 2)
        #expect(traffic.pendingCount == 0 && traffic.failures.isEmpty)
        #expect(second.requestJSON == Data(#"{"id":0,"jsonrpc":"2.0","method":"fast"}"#.utf8))
    }

    @Test func cancelledRequestStaysInTotalsWithoutInventedResponseBytes() async throws {
        let connection = RPCRecordingConnection()
        connection.pendingMethods = ["slow"]
        let slow = Task { _ = try await connection.request("slow") }
        defer { slow.cancel() }
        try await connection.waitForPendingRequests("slow")
        slow.cancel()
        do {
            try await slow.value
            Issue.record("cancelled request unexpectedly succeeded")
        } catch is CancellationError {
            let traffic = connection.traffic()
            #expect(traffic.requests.count == 1 && traffic.pendingCount == 0)
            #expect(traffic.failures.count == 1)
            #expect(traffic.requestBytes > 0 && traffic.responseBytes == 0)
        }
    }
}
