import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceScriptActionTests {
    @Test func stopReadsAuthoritativeStatusForEveryLiveState() async throws {
        for status in ["starting", "running", "restarting", "future-live-state"] {
            let (fixture, script) = try await scriptActionFixture(status: status)
            await fixture.store.stop(script)
            let params = try #require(fixture.fake.paramsForMethod("script.stop").first)
            #expect(params["workspaceId"] as? String == "workspace")
            #expect(params["scriptId"] as? String == script.id)
            #expect(fixture.fake.paramsForMethod("script.status").count == 1)
            let stopped = try #require(fixture.store.scripts(workspaceId: "workspace").first)
            #expect(stopped.status == "idle")
            #expect(stopped.hasRun)
            #expect(stopped.detectedURL == nil)
            #expect(!fixture.store.isUpdating(script))
            #expect(!fixture.fake.didCallMethod("script.remove"))
        }
    }

    @Test func stopDoesNotSendARequestForTerminalStates() async throws {
        for status in ["idle", "exited"] {
            let (fixture, script) = try await scriptActionFixture(status: status)
            fixture.fake.clearRequestLog()
            await fixture.store.stop(script)
            #expect(fixture.fake.requestLog.isEmpty)
            #expect(fixture.store.scripts(workspaceId: "workspace") == [script])
        }
    }

    @Test func removeWaitsForSuccessAndBlocksDuplicateActionsAndLaunches() async throws {
        let (fixture, script) = try await scriptActionFixture()
        fixture.fake.responseMap["script.status"] = fixture.runtime(status: "running", url: "localhost:3000")
        await fixture.store.launch(script)
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") != nil)
        fixture.fake.pendingMethods.insert("script.remove")
        let removal = Task { await fixture.store.remove(script) }
        try await fixture.fake.waitForPendingRequests("script.remove")
        #expect(fixture.store.isUpdating(script))
        #expect(fixture.store.scripts(workspaceId: "workspace").count == 1)
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
        let count = fixture.fake.requestLog.count
        await fixture.store.remove(script)
        await fixture.store.stop(script)
        await fixture.store.launch(script)
        #expect(fixture.fake.requestLog.count == count)
        fixture.fake.resolvePending("script.remove", with: ["ok": true])
        await removal.value
        #expect(fixture.store.scripts(workspaceId: "workspace").isEmpty)
        #expect(!fixture.store.isUpdating(script))
        #expect(!fixture.fake.didCallMethod("script.stop"))
    }

    @Test func stopCancelsURLWaitAndBlocksDeleteUntilStatusIsRead() async throws {
        let (fixture, script) = try await scriptActionFixture()
        fixture.fake.responseMap["script.status"] = fixture.runtime(status: "running")
        await fixture.store.launch(script)
        fixture.fake.pendingMethods = ["script.stop", "script.status"]
        let stop = Task { await fixture.store.stop(script) }
        try await fixture.fake.waitForPendingRequests("script.stop")
        #expect(!fixture.store.isLaunching(script))
        fixture.event(url: "localhost:3000")
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
        fixture.fake.resolvePending("script.stop", with: ["ok": true])
        try await fixture.fake.waitForPendingRequests("script.status")
        await fixture.store.remove(script)
        await fixture.store.launch(script)
        #expect(fixture.store.isUpdating(script))
        #expect(!fixture.fake.didCallMethod("script.remove"))
        fixture.fake.resolvePending("script.status", with: fixture.runtime(status: "idle"))
        await stop.value
        #expect(!fixture.store.isUpdating(script))
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
    }

    @Test func failedActionsKeepTheirRowAndExposeErrorUntilRetry() async throws {
        for method in ["script.stop", "script.remove"] {
            let (fixture, script) = try await scriptActionFixture()
            fixture.fake.errorMap[method] = NSError(domain: "action", code: 1, userInfo: [NSLocalizedDescriptionKey: "Request refused"])
            await performScriptAction(method, script: script, store: fixture.store)
            #expect(fixture.store.scripts(workspaceId: "workspace") == [script])
            #expect(fixture.store.errorMessage(workspaceId: "workspace") == "Request refused")
            #expect(!fixture.store.isUpdating(script))
            await fixture.store.refresh(workspaceId: "workspace")
            #expect(fixture.store.errorMessage(workspaceId: "workspace") == "Request refused")
            fixture.fake.errorMap.removeAll()
            await performScriptAction(method, script: script, store: fixture.store)
            #expect(fixture.store.errorMessage(workspaceId: "workspace") == nil)
        }
    }

    @Test func negativeRemoveAcknowledgmentDoesNotDeleteRow() async throws {
        let (fixture, script) = try await scriptActionFixture()
        fixture.fake.responseMap["script.remove"] = ["ok": false]
        await fixture.store.remove(script)
        #expect(fixture.store.scripts(workspaceId: "workspace") == [script])
        #expect(fixture.store.errorMessage(workspaceId: "workspace") != nil)
        #expect(!fixture.store.isUpdating(script))
    }

    @Test func failedStopStatusReadKeepsRowAndReportsError() async throws {
        let (fixture, script) = try await scriptActionFixture()
        fixture.fake.errorMap["script.status"] = NSError(domain: "status", code: 1, userInfo: [NSLocalizedDescriptionKey: "Status unavailable"])
        await fixture.store.stop(script)
        #expect(fixture.store.scripts(workspaceId: "workspace") == [script])
        #expect(fixture.store.errorMessage(workspaceId: "workspace") == "Status unavailable")
        #expect(!fixture.store.isUpdating(script))
    }

    @Test func removingSavedManifestScriptLeavesCandidateInMenu() async throws {
        let fixture = WorkspaceScriptFixture()
        fixture.fake.responseMap["file.list"] = [["name": "package.json", "type": "file"]]
        fixture.fake.responseMap["file.read"] = #"{"scripts":{"dev":"vite"}}"#
        var row = fixture.definition(status: "running")
        row["name"] = "dev"
        await fixture.load([row])
        let script = try #require(fixture.store.scripts(workspaceId: "workspace").first)
        #expect(script.isRegistered)
        fixture.fake.responseMap["script.remove"] = ["ok": true]
        await fixture.store.remove(script)
        let candidate = try #require(fixture.store.scripts(workspaceId: "workspace").first)
        #expect(candidate.id == "manifest:package.json:dev")
        #expect(!candidate.isRegistered)
        #expect(fixture.store.scriptsWithRuns(workspaceId: "workspace").isEmpty)
        #expect(!fixture.fake.didCallMethod("script.create"))
        #expect(!fixture.fake.didCallMethod("script.start"))
    }

    @Test func unregisteredCandidatesAndDisconnectedStoresCannotSendActions() async throws {
        let (fixture, script) = try await scriptActionFixture()
        let candidate = WorkspaceScript(id: "manifest:package.json:dev", workspaceId: "workspace", name: "dev", command: "npm run dev", status: "running", isRegistered: false)
        fixture.fake.clearRequestLog()
        await fixture.store.stop(candidate)
        await fixture.store.remove(candidate)
        fixture.fake.connectionState = .disconnected
        await fixture.store.stop(script)
        await fixture.store.remove(script)
        #expect(fixture.fake.requestLog.isEmpty)
    }

    @Test func sameIDInOtherWorkspaceAndItsLaunchAreUnaffected() async throws {
        let (fixture, script) = try await scriptActionFixture()
        await fixture.load([fixture.definition(workspaceId: "other", status: "running")], workspaceId: "other")
        let other = try #require(fixture.store.scripts(workspaceId: "other").first)
        fixture.fake.responseMap["script.status"] = fixture.runtime(status: "running")
        await fixture.store.launch(other)
        await fixture.store.remove(script)
        #expect(fixture.store.scripts(workspaceId: "workspace").isEmpty)
        #expect(fixture.store.scripts(workspaceId: "other").map(\.id) == [other.id])
        fixture.event(workspaceId: "other", url: "localhost:5000")
        #expect(fixture.store.takeBrowserToOpen(workspaceId: "other")?.url == "http://127.0.0.1:5000")
        let params = try #require(fixture.fake.paramsForMethod("script.remove").first)
        #expect(params["workspaceId"] as? String == "workspace")
        #expect(params["scriptId"] as? String == script.id)
    }
}

@MainActor
struct WorkspaceScriptActionRaceTests {
    @Test func suspensionRetiresActionsWithoutLettingOldRepliesClearNewActions() async throws {
        for method in ["script.stop", "script.remove"] {
            let (fixture, script) = try await scriptActionFixture()
            fixture.fake.pendingMethods.insert(method)
            let oldAction = Task { await performScriptAction(method, script: script, store: fixture.store) }
            try await fixture.fake.waitForPendingRequests(method)
            fixture.store.suspendObservation()
            #expect(!fixture.store.isUpdating(script))
            fixture.store.resumeObservation()
            let newAction = Task { await performScriptAction(method, script: script, store: fixture.store) }
            try await fixture.fake.waitForPendingRequests(method, count: 2)
            fixture.fake.resolvePending(method, with: ["ok": true])
            await oldAction.value
            #expect(fixture.store.isUpdating(script))
            #expect(fixture.store.scripts(workspaceId: "workspace") == [script])
            #expect(fixture.store.errorMessage(workspaceId: "workspace") == nil)
            fixture.fake.resolvePending(method, with: ["ok": true])
            await newAction.value
            #expect(!fixture.store.isUpdating(script))
            if method == "script.remove" {
                #expect(fixture.store.scripts(workspaceId: "workspace").isEmpty)
            } else {
                #expect(fixture.store.scripts(workspaceId: "workspace").first?.status == "idle")
            }
        }
    }

    @Test func suspensionDuringStopStatusReadReleasesControlsAndIgnoresLateStatus() async throws {
        let (fixture, script) = try await scriptActionFixture()
        fixture.fake.pendingMethods.insert("script.status")
        let stop = Task { await fixture.store.stop(script) }
        try await fixture.fake.waitForPendingRequests("script.status")
        fixture.store.suspendObservation()
        fixture.fake.resolvePending("script.status", with: fixture.runtime(status: "idle"))
        await stop.value
        #expect(!fixture.store.isUpdating(script))
        #expect(fixture.store.scripts(workspaceId: "workspace") == [script])
        fixture.store.resumeObservation()
        await fixture.store.remove(script)
        #expect(fixture.store.scripts(workspaceId: "workspace").isEmpty)
    }

    @Test func actionsAfterSuspensionStillWaitForAnAlreadySentStart() async throws {
        for method in ["script.stop", "script.remove"] {
            let (fixture, script) = try await scriptActionFixture(status: "idle")
            fixture.fake.responseQueueMap["script.status"] = [fixture.runtime(status: "idle")]
            fixture.fake.pendingMethods = ["script.start", method]
            let launch = Task { await fixture.store.launch(script) }
            try await fixture.fake.waitForPendingRequests("script.start")
            fixture.store.suspendObservation()
            fixture.store.resumeObservation()
            let action = Task { await performScriptAction(method, script: script, store: fixture.store) }
            try await waitUntil("resumed action waiting for start") { fixture.store.isUpdating(script) }
            #expect(!fixture.fake.didCallMethod(method))
            fixture.fake.resolvePending("script.start", with: ["ok": true])
            try await fixture.fake.waitForPendingRequests(method)
            fixture.fake.resolvePending(method, with: ["ok": true])
            await launch.value
            await action.value
            #expect(fixture.store.startTasks.isEmpty)
            #expect(!fixture.store.isUpdating(script))
            #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
            #expect(fixture.fake.paramsForMethod("script.start").count == 1)
        }
    }

    @Test func actionsWaitForAlreadySentStartAndPreventLatePresentation() async throws {
        for method in ["script.stop", "script.remove"] {
            let (fixture, script) = try await scriptActionFixture(status: "idle")
            fixture.fake.responseQueueMap["script.status"] = [fixture.runtime(status: "idle")]
            fixture.fake.pendingMethods = ["script.start", method]
            let launch = Task { await fixture.store.launch(script) }
            try await fixture.fake.waitForPendingRequests("script.start")
            let action = Task { await performScriptAction(method, script: script, store: fixture.store) }
            try await waitUntil("action waiting for start") { fixture.store.isUpdating(script) }
            #expect(!fixture.fake.didCallMethod(method))
            fixture.fake.resolvePending("script.start", with: ["ok": true])
            try await fixture.fake.waitForPendingRequests(method)
            fixture.fake.resolvePending(method, with: ["ok": true])
            await launch.value
            await action.value
            #expect(fixture.fake.paramsForMethod("script.start").count == 1)
            #expect(fixture.fake.paramsForMethod(method).count == 1)
            #expect(!fixture.store.isUpdating(script))
            #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
        }
    }

    @Test func actionsCancelPreflightSoItCannotSendStartLater() async throws {
        for method in ["script.stop", "script.remove"] {
            let (fixture, script) = try await scriptActionFixture(status: "idle")
            fixture.fake.pendingMethods.insert("script.status")
            let launch = Task { await fixture.store.launch(script) }
            try await fixture.fake.waitForPendingRequests("script.status")
            await performScriptAction(method, script: script, store: fixture.store)
            fixture.fake.resolvePending("script.status", with: fixture.runtime(status: "idle"))
            await launch.value
            #expect(!fixture.fake.didCallMethod("script.start"))
            #expect(!fixture.store.isLaunching(script))
            #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
        }
    }

    @Test func removeStillRunsWhenEarlierStartFails() async throws {
        let (fixture, script) = try await scriptActionFixture(status: "idle")
        fixture.fake.responseQueueMap["script.status"] = [fixture.runtime(status: "idle")]
        fixture.fake.pendingMethods.insert("script.start")
        let launch = Task { await fixture.store.launch(script) }
        try await fixture.fake.waitForPendingRequests("script.start")
        let removal = Task { await fixture.store.remove(script) }
        try await waitUntil("remove waiting for start") { fixture.store.isUpdating(script) }
        fixture.fake.failPending("script.start", with: NSError(domain: "start", code: 1))
        await launch.value
        await removal.value
        #expect(fixture.store.scripts(workspaceId: "workspace").isEmpty)
        #expect(fixture.store.errorMessage(workspaceId: "workspace") == nil)
    }

    @Test func removeInvalidatesAListThatWasAlreadyInFlight() async throws {
        let (fixture, script) = try await scriptActionFixture()
        fixture.fake.pendingMethods.insert("script.list")
        let refresh = Task { await fixture.store.refresh(workspaceId: "workspace") }
        try await fixture.fake.waitForPendingRequests("script.list")
        await fixture.store.remove(script)
        fixture.fake.resolvePending("script.list", with: ["scripts": [fixture.definition(status: "running")]])
        try await fixture.fake.waitForPendingRequests("script.list")
        #expect(fixture.store.scripts(workspaceId: "workspace").isEmpty)
        fixture.fake.resolvePending("script.list", with: ["scripts": []])
        await refresh.value
        #expect(fixture.store.scripts(workspaceId: "workspace").isEmpty)
    }

    @Test func stopDiscardsStatusSnapshotInvalidatedByNewerEvent() async throws {
        let (fixture, script) = try await scriptActionFixture()
        fixture.fake.pendingMethods.insert("script.status")
        let stop = Task { await fixture.store.stop(script) }
        try await fixture.fake.waitForPendingRequests("script.status")
        fixture.event(status: "restarting")
        fixture.fake.resolvePending("script.status", with: fixture.runtime(status: "idle"))
        try await fixture.fake.waitForPendingRequests("script.status")
        #expect(fixture.store.scripts(workspaceId: "workspace").first?.status == "restarting")
        fixture.fake.resolvePending("script.status", with: fixture.runtime(status: "running", url: "localhost:5000"))
        await stop.value
        #expect(fixture.store.scripts(workspaceId: "workspace").first?.detectedURL == "localhost:5000")
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
    }

    @Test func stopRetriesAStatusErrorInvalidatedByNewerEvent() async throws {
        let (fixture, script) = try await scriptActionFixture()
        fixture.fake.pendingMethods.insert("script.status")
        let stop = Task { await fixture.store.stop(script) }
        try await fixture.fake.waitForPendingRequests("script.status")
        fixture.event(status: "idle")
        fixture.fake.failPending("script.status", with: NSError(domain: "old status", code: 1))
        try await fixture.fake.waitForPendingRequests("script.status")
        fixture.fake.resolvePending("script.status", with: fixture.runtime(status: "idle"))
        await stop.value
        #expect(fixture.store.errorMessage(workspaceId: "workspace") == nil)
        #expect(!fixture.store.isUpdating(script))
    }

    @Test func repliesFromPreviousConnectionCannotChangeFreshRows() async throws {
        for method in ["script.stop", "script.remove"] {
            let (fixture, script) = try await scriptActionFixture()
            fixture.fake.pendingMethods.insert(method)
            let action = Task { await performScriptAction(method, script: script, store: fixture.store) }
            try await fixture.fake.waitForPendingRequests(method)
            fixture.fake.connectionState = .disconnected
            fixture.fake.responseMap["script.list"] = ["scripts": [fixture.definition(status: "running", url: "localhost:5000")]]
            fixture.fake.connectionState = .connected
            await fixture.store.refresh(workspaceId: "workspace")
            fixture.fake.resolvePending(method, with: ["ok": true])
            await action.value
            #expect(fixture.store.scripts(workspaceId: "workspace").first?.detectedURL == "localhost:5000")
            #expect(!fixture.store.isUpdating(script))
            #expect(fixture.store.errorMessage(workspaceId: "workspace") == nil)
        }
    }

    @Test func disconnectWhileWaitingForStartPreventsControlRequest() async throws {
        let (fixture, script) = try await scriptActionFixture(status: "idle")
        fixture.fake.responseQueueMap["script.status"] = [fixture.runtime(status: "idle")]
        fixture.fake.pendingMethods.insert("script.start")
        let launch = Task { await fixture.store.launch(script) }
        try await fixture.fake.waitForPendingRequests("script.start")
        let removal = Task { await fixture.store.remove(script) }
        try await waitUntil("remove waiting for start") { fixture.store.isUpdating(script) }
        fixture.fake.connectionState = .disconnected
        fixture.fake.resolvePending("script.start", with: ["ok": true])
        fixture.fake.connectionState = .connected
        await launch.value
        await removal.value
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(!fixture.fake.didCallMethod("script.remove"))
        #expect(!fixture.store.isUpdating(script))
    }

    @Test func oldActionCannotClearBusyStateOrSetErrorOnNewAction() async throws {
        let (fixture, script) = try await scriptActionFixture()
        fixture.fake.pendingMethods.insert("script.remove")
        let oldRemoval = Task { await fixture.store.remove(script) }
        try await fixture.fake.waitForPendingRequests("script.remove")
        fixture.fake.connectionState = .disconnected
        fixture.fake.connectionState = .connected
        await fixture.store.refresh(workspaceId: "workspace")
        let newRemoval = Task { await fixture.store.remove(script) }
        try await fixture.fake.waitForPendingRequests("script.remove", count: 2)
        fixture.fake.failPending("script.remove", with: NSError(domain: "old connection", code: 1))
        await oldRemoval.value
        #expect(fixture.store.isUpdating(script))
        #expect(fixture.store.errorMessage(workspaceId: "workspace") == nil)
        #expect(fixture.store.scripts(workspaceId: "workspace") == [script])
        fixture.fake.resolvePending("script.remove", with: ["ok": true])
        await newRemoval.value
        #expect(!fixture.store.isUpdating(script))
        #expect(fixture.store.scripts(workspaceId: "workspace").isEmpty)
    }
}

@MainActor
private func scriptActionFixture(status: String = "running") async throws -> (WorkspaceScriptFixture, WorkspaceScript) {
    let fixture = WorkspaceScriptFixture()
    fixture.fake.responseMap["script.stop"] = ["ok": true]
    fixture.fake.responseMap["script.remove"] = ["ok": true]
    fixture.fake.responseMap["script.status"] = ["status": "idle", "restartCount": 0, "stoppedAt": "2026-09-28T03:00:00Z"]
    await fixture.load([fixture.definition(status: status)])
    let script = try #require(fixture.store.scripts(workspaceId: "workspace").first)
    return (fixture, script)
}

@MainActor
private func performScriptAction(_ method: String, script: WorkspaceScript, store: WorkspaceScriptStore) async {
    if method == "script.stop" { await store.stop(script) } else { await store.remove(script) }
}
