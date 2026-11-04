#if DEBUG
import Foundation

enum DemoRepositoryScriptFixtures {
    private static var definitions: [String: [[String: Any]]] = [:]
    private static var runtimes: [String: [String: [String: Any]]] = [:]
    private static var removedScripts: [String: Set<String>] = [:]

    static func response(for method: String, params: [String: Any]) -> Any? {
        guard let workspaceId = params["workspaceId"] as? String else { return nil }
        let scriptId = params["scriptId"] as? String ?? ""
        switch method {
        case "file.list":
            return [["name": "package.json", "type": "file"], ["name": "pnpm-lock.yaml", "type": "file"]]
        case "file.read":
            return """
            {"packageManager":"pnpm@10.30.3","scripts":{
                "dev":"astro dev","build":"astro build","preview":"astro preview","astro":"astro",
                "lint":"eslint .","format":"prettier --write .","format:check":"prettier --check .",
                "test":"node --import tsx tests/run.ts","test:specwriter":"node --import tsx tests/run.ts specwriter",
                "test:specwriter:browser":"node tests/specwriter/browser.mjs"
            }}
            """
        case "script.list":
            return [
                "scripts": scripts(workspaceId: workspaceId).map { definition in
                    var row = definition
                    let id = definition["id"] as? String ?? ""
                    row["runtime"] = runtimes[workspaceId]?[id] ?? ["status": "idle", "restartCount": 0]
                    return row
                }
            ]
        case "script.create":
            return create(params: params, workspaceId: workspaceId)
        case "script.start":
            return start(scriptId: scriptId, workspaceId: workspaceId)
        case "script.status":
            return runtimes[workspaceId]?[scriptId] ?? ["status": "idle", "restartCount": 0]
        case "script.stop":
            runtimes[workspaceId, default: [:]][scriptId] = ["status": "exited", "exitCode": 0, "restartCount": 0]
            return ["ok": true, "scriptId": scriptId]
        case "script.remove":
            removedScripts[workspaceId, default: []].insert(scriptId)
            definitions[workspaceId]?.removeAll { $0["id"] as? String == scriptId }
            runtimes[workspaceId]?[scriptId] = nil
            return ["ok": true, "scriptId": scriptId]
        default:
            return nil
        }
    }

    private static func create(params: [String: Any], workspaceId: String) -> Any? {
        guard let name = params["name"] as? String,
              let command = params["command"] as? String,
              let mode = params["mode"] as? String else { return nil }
        let definition: [String: Any] = [
            "id": "demo-repo-\(name)", "workspaceId": workspaceId,
            "name": name, "command": command, "mode": mode
        ]
        definitions[workspaceId, default: []].append(definition)
        removedScripts[workspaceId]?.remove("demo-repo-\(name)")
        return definition
    }

    private static func start(scriptId: String, workspaceId: String) -> [String: Any] {
        guard let script = scripts(workspaceId: workspaceId).first(where: { $0["id"] as? String == scriptId }) else {
            return ["ok": false]
        }
        runtimes[workspaceId, default: [:]][scriptId] = script["mode"] as? String == "service"
            ? ["status": "running", "detectedUrl": "http://localhost:4321", "restartCount": 0]
            : ["status": "exited", "exitCode": 0, "restartCount": 0]
        return ["ok": true, "scriptId": scriptId]
    }

    private static func scripts(workspaceId: String) -> [[String: Any]] {
        let saved: [[String: Any]] = [
            [
                "id": "demo-verification", "workspaceId": workspaceId,
                "name": "Gradient browser verification", "command": "node tests/specwriter/browser.mjs", "mode": "command"
            ]
        ] + definitions[workspaceId, default: []]
        return saved.filter { !removedScripts[workspaceId, default: []].contains($0["id"] as? String ?? "") }
    }
}
#endif
