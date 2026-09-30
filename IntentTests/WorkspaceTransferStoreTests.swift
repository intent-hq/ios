import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceTransferStoreTests {
    @Test func loadsPreviewWithoutOpeningDestinationOrExporting() async {
        let fixture = WorkspaceTransferFixture()
        await fixture.store.loadPlan()
        #expect(fixture.store.plan?.estimatedBytes == Int64(fixture.payload.count))
        #expect(fixture.store.plan?.warnings == ["Running agents will stop."])
        #expect(fixture.target.connectLog.isEmpty)
        #expect(!fixture.source.didCallMethod("workspace.export.start"))
        #expect(!fixture.store.isBusy)
    }

    @Test func unavailablePreviewCannotStartTransfer() async {
        let fixture = WorkspaceTransferFixture()
        fixture.source.errorMap["workspace.transfer.plan"] = WorkspaceTransferFixture.error("Method not found")
        await fixture.store.loadPlan()
        #expect(fixture.store.plan == nil)
        #expect(fixture.store.errorMessage?.contains("host may need an update") == true)
        await fixture.store.transfer(to: fixture.destination, archiveSource: false)
        #expect(fixture.target.connectLog.isEmpty)
        #expect(!fixture.source.didCallMethod("workspace.export.start"))
    }

    @Test func successfulTransferUsesSeparateCredentialsAndOrderedRPCs() async throws {
        let fixture = WorkspaceTransferFixture()
        await fixture.run(archiveSource: true)
        #expect(fixture.store.isComplete)
        #expect(fixture.store.errorMessage == nil)
        #expect(fixture.store.progress == 1)
        let relevant = fixture.trace.filter { !$0.hasSuffix("client.hello") && !$0.hasSuffix("principal.me") && !$0.hasSuffix("workspace.transfer.plan") }
        let expected = [
            "target:system.status", "target:workspace.list", "source:events.subscribe", "source:workspace.export.start",
            "target:workspace.import.begin", "source:workspace.export.read", "target:workspace.import.chunk",
            "target:workspace.import.commit", "source:workspace.export.finalize", "source:events.unsubscribe"
        ]
        #expect(relevant == expected)
        let connection = try #require(fixture.target.connectLog.first)
        #expect(connection.hosts == fixture.destination.server.hosts)
        #expect(connection.token == fixture.destination.token)
        #expect(connection.certFingerprint == fixture.destination.server.certFingerprint)
        #expect(connection.tcAddress == fixture.destination.server.tcAddress)
        #expect(fixture.source.connectLog.isEmpty)
        #expect(fixture.source.disconnectCallCount == 0)
        #expect(fixture.target.disconnectCallCount == 1)
        #expect(fixture.source.eventHandlerCount == 0)
        #expect(fixture.source.paramsForMethod("workspace.export.finalize").first?["archiveSource"] as? Bool == true)
        for method in ["events.subscribe", "events.unsubscribe", "workspace.export.start", "workspace.export.read", "workspace.export.finalize"] {
            #expect(fixture.source.paramsForMethod(method).allSatisfy { $0["workspaceId"] as? String == "workspace" })
        }
        #expect(fixture.target.paramsForMethod("workspace.list").first?["includeArchived"] as? Bool == true)
    }

    @Test func successfulTransferKeepsSourceActiveByDefaultAndCannotRepeat() async {
        let fixture = WorkspaceTransferFixture()
        await fixture.run()
        #expect(fixture.source.paramsForMethod("workspace.export.finalize").first?["archiveSource"] as? Bool == false)
        await fixture.store.transfer(to: fixture.destination, archiveSource: true)
        #expect(fixture.source.paramsForMethod("workspace.export.start").count == 1)
    }

    @Test func multipleChunksAreRelayedInSequenceWithCumulativeReceipts() async throws {
        let fixture = WorkspaceTransferFixture()
        fixture.sendsReadyBeforeReply = false
        fixture.source.pendingMethods.insert("workspace.export.start")
        let first = Data("arch".utf8)
        let second = Data("ive".utf8)
        fixture.source.responseQueueMap["workspace.export.read"] = [
            ["exportId": "export", "seq": 0, "totalChunks": 2, "data": first.base64EncodedString()],
            ["exportId": "export", "seq": 1, "totalChunks": 2, "data": second.base64EncodedString()]
        ]
        fixture.target.responseQueueMap["workspace.import.chunk"] = [
            ["importId": "import", "seq": 0, "receivedBytes": first.count],
            ["importId": "import", "seq": 1, "receivedBytes": first.count + second.count]
        ]
        let task = await fixture.start()
        try await fixture.source.waitForPendingRequests("workspace.export.start")
        var ready = fixture.ready
        ready["maxChunkBytes"] = first.count
        ready["totalChunks"] = 2
        fixture.emitReady(ready)
        fixture.source.resolvePending("workspace.export.start", with: fixture.startReply)
        await task.value
        #expect(fixture.store.isComplete)
        #expect(fixture.target.paramsForMethod("workspace.import.chunk").compactMap { $0["seq"] as? Int } == [0, 1])
        #expect(fixture.store.progress == 1)
    }

    @Test(arguments: ["version", "collision", "guest", "identity", "list", "certificate"])
    func failedPreflightNeverStopsSource(reason: String) async {
        let fixture = WorkspaceTransferFixture()
        switch reason {
        case "version": fixture.target.responseMap["system.status"] = ["version": "older"]
        case "collision": fixture.target.responseMap["workspace.list"] = ["workspaces": [["id": "workspace", "status": "archived"]]]
        case "guest": fixture.target.responseMap["principal.me"] = ["id": "test-owner", "isAdministrator": false]
        case "identity": fixture.destination.principal = .demoOwner
        case "list": fixture.target.responseMap["workspace.list"] = ["unexpected": true]
        default: fixture.target.connectError = WorkspaceTransferFixture.error("Certificate changed")
        }
        await fixture.run()
        #expect(!fixture.store.isComplete)
        #expect(fixture.store.errorMessage != nil)
        #expect(!fixture.source.didCallMethod("workspace.export.start"))
        #expect(!fixture.source.didCallMethod("events.subscribe"))
        #expect(fixture.source.disconnectCallCount == 0)
        #expect(fixture.target.disconnectCallCount == 1)
    }

    @Test func guestSourceCannotPreviewOrTransfer() async {
        let fixture = WorkspaceTransferFixture()
        fixture.source.responseMap["principal.me"] = ["id": "guest", "isAdministrator": false]
        await fixture.run()
        #expect(fixture.store.plan == nil)
        #expect(fixture.target.connectLog.isEmpty)
        #expect(!fixture.source.didCallMethod("workspace.export.start"))
    }

    @Test func chunkFailureCleansBothSidesAndNeverArchives() async {
        let fixture = WorkspaceTransferFixture()
        fixture.target.errorMap["workspace.import.chunk"] = WorkspaceTransferFixture.error("Disk full")
        await fixture.run(archiveSource: true)
        #expect(!fixture.store.isComplete)
        #expect(fixture.store.errorMessage == "Disk full")
        #expect(fixture.target.didCallMethod("workspace.import.abort"))
        #expect(fixture.source.didCallMethod("workspace.export.abort"))
        #expect(!fixture.source.didCallMethod("workspace.export.finalize"))
        #expect(!fixture.target.didCallMethod("workspace.import.commit"))
        #expect(fixture.source.eventHandlerCount == 0)
        #expect(fixture.target.disconnectCallCount == 1)
    }

    @Test(arguments: ["data", "sequence", "size", "receipt"])
    func invalidChunkCannotCommit(reason: String) async {
        let fixture = WorkspaceTransferFixture()
        var chunk = fixture.source.responseMap["workspace.export.read"] as? [String: Any] ?? [:]
        switch reason {
        case "data": chunk["data"] = "not base64"
        case "sequence": chunk["seq"] = 1
        case "size": chunk["data"] = Data("too short".utf8).base64EncodedString()
        default: fixture.target.responseMap["workspace.import.chunk"] = ["receivedBytes": 0]
        }
        fixture.source.responseMap["workspace.export.read"] = chunk
        await fixture.run()
        #expect(!fixture.store.isComplete)
        #expect(!fixture.target.didCallMethod("workspace.import.commit"))
        #expect(fixture.target.didCallMethod("workspace.import.abort"))
        #expect(fixture.source.didCallMethod("workspace.export.abort"))
    }

    @Test(arguments: [false, true])
    func failedArchivalKeepsSuccessfulImportAndWarnsAgainstRepeating(malformedReply: Bool) async {
        let fixture = WorkspaceTransferFixture()
        if malformedReply {
            fixture.source.responseMap["workspace.export.finalize"] = ["finalized": false]
        } else {
            fixture.source.errorMap["workspace.export.finalize"] = WorkspaceTransferFixture.error("Archive failed")
        }
        await fixture.run(archiveSource: true)
        #expect(fixture.store.isComplete)
        #expect(fixture.store.errorMessage?.contains("transferred successfully") == true)
        #expect(fixture.store.errorMessage?.contains("Do not repeat") == true)
        #expect(!fixture.target.didCallMethod("workspace.import.abort"))
        #expect(fixture.source.didCallMethod("workspace.export.abort"))
        await fixture.store.transfer(to: fixture.destination, archiveSource: false)
        #expect(fixture.target.paramsForMethod("workspace.import.commit").count == 1)
    }

    @Test(arguments: [false, true])
    func unconfirmedCommitNeverArchives(malformedReply: Bool) async {
        let fixture = WorkspaceTransferFixture()
        if malformedReply {
            fixture.target.responseMap["workspace.import.commit"] = ["workspace": ["id": "other"]]
        } else {
            fixture.target.errorMap["workspace.import.commit"] = WorkspaceTransferFixture.error("Request timed out")
        }
        await fixture.run(archiveSource: true)
        #expect(!fixture.store.isComplete)
        #expect(fixture.store.errorMessage?.contains("may already contain the workspace") == true)
        #expect(!fixture.source.didCallMethod("workspace.export.finalize"))
        #expect(fixture.source.didCallMethod("workspace.export.abort"))
    }
}
