import Foundation
@testable import Intent
import Testing

@MainActor
struct ProviderManagementStoreTests {
    private func entry(
        _ id: String, visible: Bool = true, canBeDisabled: Bool = true, supportsTest: Bool = true
    ) -> [String: Any] {
        [
            "id": id, "displayName": "Provider \(id)", "visible": visible,
            "canBeDisabled": canBeDisabled, "supportsTestPrompt": supportsTest
        ]
    }

    private func settings(_ value: [String: Bool]) -> [String: Any] {
        ["path": "providers.enabled", "value": value]
    }

    private func host() -> RPCRecordingConnection {
        let host = RPCRecordingConnection()
        host.simulateConnect()
        host.responseMap["providers.catalog"] = ["providers": [entry("codex"), entry("auggie")]]
        host.responseMap["settings.get"] = settings(["codex": true])
        host.responseMap["host.providerAuthStatus"] = [
            "providers": [["id": "codex", "authenticated": true], ["id": "auggie", "authenticated": false]]
        ]
        host.responseMap["settings.update"] = ["applied": []]
        host.responseMap["host.providerTestPrompt"] = ["ok": true]
        return host
    }

    @Test func catalogPolicyPreservesDisabledAndUnknownAuthenticationRows() async {
        let host = host()
        host.responseMap["providers.catalog"] = ["providers": [
            entry("codex"), entry("auggie"), entry("hidden", visible: false),
            entry("always", canBeDisabled: false), entry("new", supportsTest: false)
        ]]
        host.responseMap["settings.get"] = settings(["codex": true, "always": false, "hidden": true])
        let store = ProviderManagementStore(connectionManager: host)
        await store.load()
        #expect(store.providers.map(\.id) == ["codex", "auggie", "always", "new"])
        #expect(store.providers.map(\.enabled) == [true, false, true, false])
        #expect(store.providers.map(\.authentication) == [.signedIn, .signedOut, .unknown, .unknown])
        #expect(store.providers.last?.supportsTestPrompt == false)
        #expect(host.paramsForMethod("host.providerAuthStatus").first?["force"] as? Bool == true)
    }

    @Test func unsetMapAndOlderCapabilitiesAreSupportedWithoutInventingActions() async {
        let host = host()
        var provider = entry("codex")
        provider.removeValue(forKey: "supportsTestPrompt")
        host.responseMap["providers.catalog"] = ["providers": [provider]]
        host.responseMap["settings.get"] = ["path": "providers.enabled", "value": NSNull()]
        host.responseMap["host.providerAuthStatus"] = ["providers": [["id": "codex", "authenticated": NSNull()]]]
        let store = ProviderManagementStore(connectionManager: host)
        await store.load()
        #expect(store.hasLoaded)
        #expect(store.providers.first?.enabled == false)
        #expect(store.providers.first?.supportsTestPrompt == false)
        #expect(store.providers.first?.authentication == .unknown)
    }

    @Test func malformedPolicyDoesNotBecomeWritable() async {
        let invalidSettings: [[String: Any]] = [
            [:], ["path": "providers.enabled"], ["path": "wrong", "value": [:]],
            ["path": "providers.enabled", "value": ["codex": 1]],
            ["path": "providers.enabled", "value": ["codex": "true"]]
        ]
        for value in invalidSettings {
            let host = host()
            host.responseMap["settings.get"] = value
            let store = ProviderManagementStore(connectionManager: host)
            await store.load()
            #expect(!store.canManage)
            #expect(store.errorMessage != nil)
            #expect(store.providers.isEmpty)
        }
        for entries in [[entry("codex"), entry("codex")], [entry("")], [["id": "codex"]]] {
            let host = host()
            host.responseMap["providers.catalog"] = ["providers": entries]
            let store = ProviderManagementStore(connectionManager: host)
            await store.load()
            #expect(!store.hasLoaded)
        }
    }

    @Test(arguments: ["providers.catalog", "settings.get", "host.providerAuthStatus"])
    func failedRefreshRetainsConfirmedStateAndRetryRestoresControls(method: String) async {
        let host = host()
        let store = ProviderManagementStore(connectionManager: host)
        await store.load()
        let confirmed = store.providers
        host.errorMap[method] = NSError(domain: "test", code: -1)
        await store.load()
        #expect(store.providers == confirmed)
        #expect(store.errorMessage != nil)
        #expect(!store.canManage)
        host.errorMap[method] = nil
        await store.load()
        #expect(store.canManage)
        #expect(store.errorMessage == nil)
    }

    @Test func mutationUsesLatestHostMapAndWaitsForConfirmation() async throws {
        let host = host()
        let store = ProviderManagementStore(connectionManager: host)
        await store.load()
        host.responseMap["settings.get"] = settings(["codex": true, "future-provider": true, "auggie": true])
        host.pendingMethods = ["settings.update"]
        let write = Task { await store.setEnabled(false, providerID: "codex") }
        try await host.waitForPendingRequests("settings.update")
        let params = try #require(host.paramsForMethod("settings.update").last)
        let changes = try #require(params["changes"] as? [[String: Any]])
        #expect(changes.first?["path"] as? String == "providers.enabled")
        #expect(changes.first?["value"] as? [String: Bool] == [
            "codex": false, "future-provider": true, "auggie": true
        ])
        #expect(store.providers.first?.enabled == true)
        #expect(!store.canManage)
        await store.setEnabled(true, providerID: "auggie")
        #expect(host.paramsForMethod("settings.update").count == 1)
        host.responseMap["settings.get"] = settings(["codex": false, "future-provider": true, "auggie": true])
        host.resolvePending("settings.update", with: ["applied": changes])
        await write.value
        #expect(store.providers.map(\.enabled) == [false, true])
        #expect(store.canManage)
    }

    @Test(arguments: ["settings.update", "confirmation"])
    func unconfirmedMutationRetainsStateUntilReload(failure: String) async {
        let host = host()
        let store = ProviderManagementStore(connectionManager: host)
        await store.load()
        let confirmed = store.providers
        if failure == "settings.update" {
            host.errorMap["settings.update"] = NSError(domain: "test", code: -1)
        } else {
            host.responseForRequest = { [weak host] method, _ in
                if method == "settings.update" {
                    host?.errorMap["settings.get"] = NSError(domain: "test", code: -1)
                }
                return nil
            }
        }
        await store.setEnabled(false, providerID: "codex")
        #expect(store.providers == confirmed)
        #expect(store.errorMessage != nil)
        #expect(!store.canManage)
    }

    @Test func prohibitedMutationsNeverSendRequests() async {
        let host = host()
        host.responseMap["providers.catalog"] = ["providers": [entry("always", canBeDisabled: false)]]
        let store = ProviderManagementStore(connectionManager: host)
        await store.setEnabled(true, providerID: "always")
        await store.load()
        await store.setEnabled(false, providerID: "always")
        await store.setEnabled(true, providerID: "missing")
        host.simulateDisconnect()
        await store.setEnabled(false, providerID: "always")
        #expect(!host.didCallMethod("settings.update"))
    }

    @Test func invalidationRejectsLateMutationAndIsolatesHosts() async throws {
        let firstHost = host()
        let secondHost = host()
        secondHost.responseMap["settings.get"] = settings(["auggie": true])
        let first = ProviderManagementStore(connectionManager: firstHost)
        let second = ProviderManagementStore(connectionManager: secondHost)
        await first.load()
        await second.load()
        firstHost.pendingMethods = ["settings.update"]
        let write = Task { await first.setEnabled(false, providerID: "codex") }
        try await firstHost.waitForPendingRequests("settings.update")
        first.invalidate()
        firstHost.resolvePending("settings.update", with: ["applied": []])
        await write.value
        #expect(!first.hasLoaded)
        #expect(first.providers.isEmpty)
        #expect(first.errorMessage == nil)
        #expect(second.providers.map(\.enabled) == [false, true])
        #expect(!secondHost.didCallMethod("settings.update"))
    }

    @Test(arguments: ["auth-required", "not-installed", "unsupported", "busy", "timeout", "error", "future-reason"])
    func liveTestsExposeRetryGuidanceAndRefreshAuthentication(reason: String) async {
        let host = host()
        let store = ProviderManagementStore(connectionManager: host)
        await store.load()
        host.responseMap["host.providerTestPrompt"] = ["ok": false, "reason": reason, "message": "private diagnostic"]
        host.responseMap["host.providerAuthStatus"] = ["providers": [["id": "codex", "authenticated": false]]]
        await store.testProvider("codex")
        #expect(store.testMessages["codex"] != nil)
        #expect(store.testMessages["codex"]?.contains("private diagnostic") == false)
        #expect(store.providers.first?.authentication == .signedOut)
        #expect(host.paramsForMethod("host.providerTestPrompt").first?["providerId"] as? String == "codex")
        #expect(store.canManage)
    }

    @Test func liveTestRequiresCapabilityAndEnablement() async {
        let host = host()
        host.responseMap["providers.catalog"] = ["providers": [entry("codex", supportsTest: false), entry("auggie")]]
        let store = ProviderManagementStore(connectionManager: host)
        await store.load()
        await store.testProvider("codex")
        await store.testProvider("auggie")
        await store.testProvider("unknown")
        #expect(!host.didCallMethod("host.providerTestPrompt"))
    }

    @Test func successfulTestAndTransportFailureHaveDistinctOutcomes() async {
        let host = host()
        let store = ProviderManagementStore(connectionManager: host)
        await store.load()
        await store.testProvider("codex")
        #expect(store.testMessages["codex"]?.contains("Test passed") == true)
        host.errorMap["host.providerTestPrompt"] = NSError(domain: "test", code: -1)
        await store.testProvider("codex")
        #expect(store.testMessages["codex"] == nil)
        #expect(store.providers.first?.authentication == .signedIn)
        #expect(store.errorMessage != nil)
    }

    @Test(arguments: ["https://example.com/sign-in", "http://example.com", "file:///secret", "javascript:alert(1)"])
    func documentationLinksOnlyAllowHTTPS(value: String) async {
        let host = host()
        var provider = entry("codex")
        provider["loginDocsUrl"] = value
        host.responseMap["providers.catalog"] = ["providers": [provider]]
        let store = ProviderManagementStore(connectionManager: host)
        await store.load()
        #expect((store.providers.first?.loginDocsURL != nil) == value.hasPrefix("https://"))
    }
}

extension ProviderManagementStoreTests {
    @Test func malformedAuthenticationCannotReplaceConfirmedStatus() async {
        let host = host()
        let store = ProviderManagementStore(connectionManager: host)
        await store.load()
        let confirmed = store.providers
        let badRows: [[[String: Any]]] = [
            [["id": "codex", "authenticated": 1]],
            [["id": "codex", "authenticated": "true"]],
            [["id": "codex", "authenticated": true], ["id": "codex", "authenticated": false]]
        ]
        for rows in badRows {
            host.responseMap["host.providerAuthStatus"] = ["providers": rows]
            await store.load()
            #expect(store.providers == confirmed)
            #expect(!store.canManage)
            #expect(store.errorMessage != nil)
        }
    }

    @Test func lateLoadCannotOverwriteAReconnectedSnapshot() async throws {
        let host = host()
        host.pendingMethods = ["settings.get"]
        let store = ProviderManagementStore(connectionManager: host)
        let oldLoad = Task { await store.load() }
        try await host.waitForPendingRequests("settings.get")
        store.invalidate()
        host.pendingMethods = []
        host.responseMap["settings.get"] = settings(["auggie": true])
        await store.load()
        let reconnected = store.providers
        host.resolvePending("settings.get", with: settings(["codex": true]))
        await oldLoad.value
        #expect(store.providers == reconnected)
        #expect(store.providers.map(\.enabled) == [false, true])
        #expect(store.canManage)
    }

    @Test func readbackMismatchShowsAuthoritativeStateAndRequiresRefresh() async {
        let host = host()
        let store = ProviderManagementStore(connectionManager: host)
        await store.load()
        // The write acknowledges but the authoritative read still says enabled.
        await store.setEnabled(false, providerID: "codex")
        #expect(store.providers.first?.enabled == true)
        #expect(store.errorMessage != nil)
        #expect(!store.canManage)
    }

    @Test func offlineLoadDoesNotSendRequests() async {
        let host = host()
        host.simulateDisconnect()
        let store = ProviderManagementStore(connectionManager: host)
        await store.load()
        #expect(host.recordedRequests.isEmpty)
        #expect(store.errorMessage?.contains("Reconnect") == true)
        #expect(!store.canManage)
    }
}
