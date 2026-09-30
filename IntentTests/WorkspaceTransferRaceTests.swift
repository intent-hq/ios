import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceTransferRaceTests {
    @Test func earlyEventsMustMatchTheStartReplyExportID() async throws {
        let fixture = WorkspaceTransferFixture()
        fixture.sendsReadyBeforeReply = false
        fixture.source.pendingMethods.insert("workspace.export.start")
        let task = await fixture.start()
        try await fixture.source.waitForPendingRequests("workspace.export.start")
        var unrelated = fixture.ready
        unrelated["exportId"] = "unrelated-export"
        fixture.emitReady(unrelated)
        fixture.emitReady()
        #expect(!fixture.target.didCallMethod("workspace.import.begin"))
        fixture.source.resolvePending("workspace.export.start", with: fixture.startReply)
        await task.value
        #expect(fixture.store.isComplete)
        #expect(fixture.source.paramsForMethod("workspace.export.read").first?["exportId"] as? String == "export")
    }

    @Test func cancelDuringStartWaitsForIDThenAborts() async throws {
        let fixture = WorkspaceTransferFixture()
        fixture.source.pendingMethods.insert("workspace.export.start")
        let task = await fixture.start()
        try await fixture.source.waitForPendingRequests("workspace.export.start")
        fixture.store.cancel()
        #expect(fixture.store.isBusy)
        #expect(!fixture.source.didCallMethod("workspace.export.abort"))
        fixture.source.resolvePending("workspace.export.start", with: fixture.startReply)
        await task.value
        #expect(!fixture.store.isBusy)
        #expect(!fixture.store.isComplete)
        #expect(fixture.store.statusMessage.contains("cancelled"))
        #expect(fixture.source.paramsForMethod("workspace.export.abort").first?["exportId"] as? String == "export")
        #expect(fixture.source.paramsForMethod("workspace.export.abort").first?["workspaceId"] as? String == "workspace")
        #expect(!fixture.target.didCallMethod("workspace.import.begin"))
        #expect(fixture.source.eventHandlerCount == 0)
    }

    @Test func cancelDuringImportBeginWaitsForIDThenCleansBothSides() async throws {
        let fixture = WorkspaceTransferFixture()
        fixture.target.pendingMethods.insert("workspace.import.begin")
        let task = await fixture.start()
        try await fixture.target.waitForPendingRequests("workspace.import.begin")
        fixture.store.cancel()
        #expect(fixture.store.isBusy)
        #expect(!fixture.target.didCallMethod("workspace.import.abort"))
        fixture.target.resolvePending("workspace.import.begin", with: fixture.beginReply)
        await task.value
        #expect(!fixture.store.isComplete)
        #expect(fixture.target.paramsForMethod("workspace.import.abort").first?["importId"] as? String == "import")
        #expect(fixture.source.didCallMethod("workspace.export.abort"))
        #expect(!fixture.source.didCallMethod("workspace.export.read"))
        #expect(!fixture.target.didCallMethod("workspace.import.commit"))
    }

    @Test func cancellationCannotInterruptCommitOrItsFinalization() async throws {
        let fixture = WorkspaceTransferFixture()
        fixture.target.pendingMethods.insert("workspace.import.commit")
        let task = await fixture.start(archiveSource: true)
        try await fixture.target.waitForPendingRequests("workspace.import.commit")
        #expect(!fixture.store.canCancel)
        #expect(!fixture.source.didCallMethod("workspace.export.finalize"))
        fixture.emit(
            type: "workspace:transfer:progress",
            data: ["workspaceId": "workspace", "exportId": "export", "stage": "writing-archive"]
        )
        #expect(!fixture.store.canCancel)
        fixture.store.cancel()
        task.cancel()
        #expect(fixture.store.isBusy)
        fixture.target.resolvePending("workspace.import.commit", with: fixture.commitReply)
        await task.value
        #expect(fixture.store.isComplete)
        #expect(fixture.store.errorMessage == nil)
        #expect(fixture.source.paramsForMethod("workspace.export.finalize").first?["archiveSource"] as? Bool == true)
        #expect(!fixture.target.didCallMethod("workspace.import.abort"))
    }

    @Test func cancelBuildUnsubscribesAndLeavesTheSourceAvailable() async throws {
        let fixture = WorkspaceTransferFixture()
        fixture.sendsReadyBeforeReply = false
        let task = await fixture.start()
        try await fixture.source.waitForRequests("workspace.export.start")
        fixture.store.cancel()
        await task.value
        #expect(fixture.source.didCallMethod("workspace.export.abort"))
        #expect(fixture.source.didCallMethod("events.unsubscribe"))
        #expect(fixture.source.eventHandlerCount == 0)
        #expect(fixture.source.disconnectCallCount == 0)
        #expect(fixture.target.disconnectCallCount == 1)
    }

    @Test func exportFailureBeforeStartReplyIsNotLost() async throws {
        let fixture = WorkspaceTransferFixture()
        fixture.sendsReadyBeforeReply = false
        fixture.source.pendingMethods.insert("workspace.export.start")
        let task = await fixture.start()
        try await fixture.source.waitForPendingRequests("workspace.export.start")
        fixture.emit(
            type: "workspace:transfer:failed",
            data: ["workspaceId": "workspace", "exportId": "export", "reason": "Could not build archive"]
        )
        fixture.source.resolvePending("workspace.export.start", with: fixture.startReply)
        await task.value
        #expect(fixture.store.errorMessage == "Could not build archive")
        #expect(!fixture.target.didCallMethod("workspace.import.begin"))
        #expect(fixture.source.didCallMethod("workspace.export.abort"))
    }

    @Test func disconnectionSettlesTheBuildWaitWithoutWaitingForDeadline() async throws {
        let fixture = WorkspaceTransferFixture()
        fixture.sendsReadyBeforeReply = false
        let task = await fixture.start()
        try await fixture.source.waitForRequests("workspace.export.start")
        fixture.target.simulateDisconnect()
        await task.value
        #expect(fixture.store.errorMessage?.contains("destination disconnected") == true)
        #expect(!fixture.store.isBusy)
        #expect(!fixture.target.didCallMethod("workspace.import.commit"))
        #expect(fixture.source.didCallMethod("workspace.export.abort"))
    }

    @Test func buildDeadlineCleansExportAndEventRegistration() async throws {
        let sleeper = WorkspaceTransferSleeper()
        var timing = WorkspaceTransferTiming()
        timing.sleep = { await sleeper.sleep($0) }
        let fixture = WorkspaceTransferFixture(timing: timing)
        fixture.sendsReadyBeforeReply = false
        let task = await fixture.start()
        let deadline = Duration.seconds(timing.build)
        try await waitUntil("archive deadline installed") { sleeper.requested.contains(deadline) }
        sleeper.expire(deadline)
        await task.value
        #expect(fixture.store.errorMessage?.contains("too long to prepare") == true)
        #expect(fixture.source.didCallMethod("workspace.export.abort"))
        #expect(fixture.source.eventHandlerCount == 0)
        #expect(!fixture.target.didCallMethod("workspace.import.begin"))
    }

    @Test func preflightDeadlineNeverStartsAnExport() async throws {
        let sleeper = WorkspaceTransferSleeper()
        var timing = WorkspaceTransferTiming()
        timing.sleep = { await sleeper.sleep($0) }
        let fixture = WorkspaceTransferFixture(timing: timing)
        fixture.target.pendingMethods.insert("system.status")
        let task = await fixture.start()
        try await fixture.target.waitForPendingRequests("system.status")
        let deadline = Duration.seconds(timing.preflight)
        try await waitUntil("preflight deadline installed") { sleeper.requested.contains(deadline) }
        sleeper.expire(deadline)
        await task.value
        #expect(fixture.store.errorMessage?.contains("too long to connect") == true)
        #expect(!fixture.source.didCallMethod("workspace.export.start"))
        #expect(fixture.target.disconnectCallCount == 1)
    }

    @Test func lostStartAcknowledgementDoesNotAbortAnUnprovenExportID() async {
        let fixture = WorkspaceTransferFixture()
        fixture.source.errorMap["workspace.export.start"] = WorkspaceTransferFixture.error("Request timed out")
        await fixture.run()
        #expect(!fixture.source.didCallMethod("workspace.export.abort"))
        #expect(fixture.store.errorMessage?.contains("cleanup could not be confirmed on the source") == true)
        #expect(!fixture.target.didCallMethod("workspace.import.begin"))
    }
}

@MainActor
private final class WorkspaceTransferSleeper {
    private var gates: [Duration: TestGate] = [:]
    private(set) var requested: Set<Duration> = []

    func sleep(_ duration: Duration) async {
        let gate = TestGate()
        gates[duration] = gate
        requested.insert(duration)
        await withTaskCancellationHandler {
            await gate.wait()
        } onCancel: {
            gate.open()
        }
    }

    func expire(_ duration: Duration) { gates[duration]?.open() }
}
