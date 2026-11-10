import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceScriptFixture {
    let fake: FakeConnectionManager
    let store: WorkspaceScriptStore

    init(fake: FakeConnectionManager = FakeConnectionManager()) {
        self.fake = fake
        fake.connectionState = .connected
        fake.responseMap["events.subscribe"] = ["subscriptionId": "scripts-sub"]
        fake.responseMap["events.unsubscribe"] = ["ok": true]
        fake.responseMap["script.list"] = ["scripts": []]
        fake.responseMap["script.start"] = ["ok": true, "scriptId": "preview"]
        fake.responseMap["script.status"] = ["status": "starting", "restartCount": 0]
        store = WorkspaceScriptStore(connection: fake)
    }

    func definition(
        id: String = "preview",
        workspaceId: String = "workspace",
        status: String = "idle",
        url: String? = nil,
        error: String? = nil
    ) -> [String: Any] {
        [
            "id": id, "workspaceId": workspaceId, "name": "Web preview", "command": "npm run dev",
            "runtime": runtime(status: status, url: url, error: error)
        ]
    }

    func runtime(status: String, url: String? = nil, error: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["status": status, "restartCount": 0]
        if let url { result["detectedUrl"] = url }
        if let error { result["error"] = error }
        if status == "exited" { result["exitCode"] = error == nil ? 0 : -1 }
        return result
    }

    func load(_ rows: [[String: Any]], workspaceId: String = "workspace") async {
        fake.responseMap["script.list"] = ["scripts": rows]
        await store.refresh(workspaceId: workspaceId)
    }

    func idleScript(id: String = "preview", workspaceId: String = "workspace") async throws -> WorkspaceScript {
        await load([definition(id: id, workspaceId: workspaceId)], workspaceId: workspaceId)
        return try #require(store.scripts(workspaceId: workspaceId).first)
    }

    func startReplies(status: String = "starting", url: String? = nil, error: String? = nil) {
        fake.responseQueueMap["script.status"] = [
            runtime(status: "idle"), runtime(status: status, url: url, error: error)
        ]
    }

    func event(
        id: String = "preview",
        workspaceId: String = "workspace",
        status: String = "running",
        url: String? = nil,
        error: String? = nil,
        subscriptionId: String = "scripts-sub"
    ) {
        var data = runtime(status: status, url: url, error: error)
        data["scriptId"] = id
        deliver(type: "script:state", workspaceId: workspaceId, data: data, subscriptionId: subscriptionId)
    }

    func changed(id: String = "preview", action: String = "updated") {
        deliver(type: "script:changed", workspaceId: "workspace", data: ["scriptId": id, "action": action])
    }

    func deliver(type: String, workspaceId: String, data: [String: Any], subscriptionId: String = "scripts-sub") {
        fake.deliverEvent(method: "events.event", params: [
            "subscriptionId": subscriptionId,
            "event": ["type": type, "workspaceId": workspaceId, "data": data]
        ])
    }
}
