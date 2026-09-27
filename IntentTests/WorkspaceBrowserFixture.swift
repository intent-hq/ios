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
        store = WorkspaceBrowserStore(connection: fake, backendID: backendID, defaults: defaults)
    }

    func script(
        id: String = "preview", workspaceId: String = "workspace", status: String = "running",
        url: String = "http://localhost:3000", command: String = "npm run dev"
    ) -> [String: Any] {
        [
            "id": id, "workspaceId": workspaceId, "name": "Web preview", "command": command,
            "runtime": ["status": status, "detectedUrl": url, "restartCount": 0]
        ]
    }

    func event(
        type: String = "script:state", workspaceId: String = "workspace", id: String = "preview",
        status: String = "running", action: String = "updated", subscriptionId: String = "browser-sub"
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
