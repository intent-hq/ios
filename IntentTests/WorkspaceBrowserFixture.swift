import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceBrowserFixture {
    let fake: FakeConnectionManager
    let store: WorkspaceBrowserStore
    let defaults: UserDefaults
    let backendID = BackendID(UUID())

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "WorkspaceBrowserTests.\(UUID().uuidString)"))
        fake = FakeConnectionManager()
        fake.connectionState = .connected
        fake.responseMap["events.subscribe"] = ["subscriptionId": "browser-sub"]
        fake.responseMap["script.list"] = ["scripts": []]
        fake.responseMap["browser.listTabs"] = ["tabs": []]
        store = WorkspaceBrowserStore(connection: fake, backendID: backendID, defaults: defaults)
    }

    func tab(
        id: String = "agent-preview",
        workspaceId: String = "workspace",
        url: String = "http://localhost:3000/docs",
        requestedURL: String? = nil
    ) -> [String: Any] {
        var tab: [String: Any] = [
            "tabId": id, "workspaceId": workspaceId, "url": url, "title": "Agent preview",
            "hostClientId": "desktop", "ownerAgentId": "agent-one", "visibility": "hidden", "hostConnected": true
        ]
        if let requestedURL { tab["requestedUrl"] = requestedURL }
        return tab
    }

    func tabEvent(
        tab: [String: Any],
        type: String = "browser:tab-opened",
        workspaceId: String = "workspace",
        subscriptionId: String = "browser-sub"
    ) {
        fake.deliverEvent(method: "events.event", params: [
            "subscriptionId": subscriptionId,
            "event": ["type": type, "workspaceId": workspaceId, "data": ["tab": tab]]
        ])
    }

    func script(
        id: String = "preview",
        workspaceId: String = "workspace",
        status: String = "running",
        url: String = "http://localhost:3000",
        command: String = "npm run dev"
    ) -> [String: Any] {
        [
            "id": id, "workspaceId": workspaceId, "name": "Web preview", "command": command,
            "runtime": ["status": status, "detectedUrl": url, "restartCount": 0]
        ]
    }

    func event(
        type: String = "script:state",
        workspaceId: String = "workspace",
        id: String = "preview",
        status: String = "running",
        action: String = "updated",
        subscriptionId: String = "browser-sub"
    ) {
        fake.deliverEvent(method: "events.event", params: [
            "subscriptionId": subscriptionId,
            "event": [
                "type": type, "workspaceId": workspaceId,
                "data": ["scriptId": id, "status": status, "action": action]
            ]
        ])
    }
}
