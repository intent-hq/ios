import Foundation

enum DemoFilesFixtures {
    static func response(for method: String, params: [String: Any]) -> Any? {
        let path = params["path"] as? String ?? "."
        switch method {
        case "file.list":
            return directories[path] ?? []
        case "file.readChunk":
            guard let text = contents[path] else { return nil }
            let bytes = Data(text.utf8)
            let offset = params["offset"] as? Int ?? 0
            let length = params["length"] as? Int ?? 0
            guard offset >= 0, length > 0 else { return [:] }
            let chunk = bytes.dropFirst(min(offset, bytes.count)).prefix(length)
            return ["content": chunk.base64EncodedString(), "bytesRead": chunk.count, "size": bytes.count]
        default:
            return nil
        }
    }

    private static let directories: [String: [[String: String]]] = [
        ".": [
            ["name": "README.md", "type": "file"],
            ["name": "Config", "type": "directory"],
            ["name": "Scripts", "type": "directory"],
            ["name": "Sources", "type": "directory"],
            ["name": "Tests", "type": "directory"],
            ["name": "Web", "type": "directory"],
            ["name": "docs", "type": "directory"],
            ["name": ".gitignore", "type": "file"]
        ],
        "Sources": [
            ["name": "Analytics.swift", "type": "file"],
            ["name": "Analytics", "type": "directory"],
            ["name": "buffer.rs", "type": "file"],
            ["name": "collector.go", "type": "file"],
            ["name": "report.py", "type": "file"]
        ],
        "Sources/Analytics": [["name": "Events.swift", "type": "file"]],
        "Tests": [["name": "AnalyticsTests.swift", "type": "file"]],
        "Config": [
            ["name": "analytics.json", "type": "file"],
            ["name": "analytics.yaml", "type": "file"],
            ["name": "analytics.toml", "type": "file"],
            ["name": "delivery.patch", "type": "file"],
            ["name": "nginx.conf", "type": "file"]
        ],
        "Web": [
            ["name": "activity.js", "type": "file"],
            ["name": "collector.ts", "type": "file"],
            ["name": "dashboard.css", "type": "file"],
            ["name": "dashboard.xml", "type": "file"],
            ["name": "index.html", "type": "file"]
        ],
        "Scripts": [["name": "report.sh", "type": "file"]],
        "docs": []
    ]

    private static let contents = [
        "README.md": DemoMarkupFileFixtures.markdown,
        ".gitignore": ".build/\n.DS_Store\n",
        "Sources/Analytics.swift": DemoSourceFileFixtures.swift,
        "Sources/report.py": DemoSourceFileFixtures.python,
        "Sources/collector.go": DemoSourceFileFixtures.golang,
        "Sources/buffer.rs": DemoSourceFileFixtures.rust,
        "Config/analytics.json": DemoConfigurationFileFixtures.json,
        "Config/analytics.yaml": DemoConfigurationFileFixtures.yaml,
        "Config/analytics.toml": DemoConfigurationFileFixtures.toml,
        "Config/nginx.conf": DemoConfigurationFileFixtures.nginx,
        "Config/delivery.patch": DemoMarkupFileFixtures.patch,
        "Web/dashboard.xml": DemoMarkupFileFixtures.xml,
        "Web/index.html": DemoMarkupFileFixtures.html,
        "Web/activity.js": DemoWebFileFixtures.javascript,
        "Web/collector.ts": DemoWebFileFixtures.typescript,
        "Web/dashboard.css": DemoWebFileFixtures.css,
        "Scripts/report.sh": DemoWebFileFixtures.shell,
        "Sources/Analytics/Events.swift": events,
        "Tests/AnalyticsTests.swift": DemoSourceFileFixtures.swiftTests
    ]

    static let events = """
        import Foundation

        // Events keep the dashboard up to date.
        enum Event: String {
            case workspaceOpened = "workspace.opened"
            case taskCompleted = "task.completed"
        }

        struct Analytics {
            let enabled = true
            let batchSize = 20

            /* Events contain names only.
               Never include user prompts or file paths. */
            func track(_ event: Event) {
                guard enabled else { return }
                print("Tracked: \\(event.rawValue)")
            }

            @discardableResult
            func trackBatch(_ events: [Event]) -> Int {
                let batch = events.prefix(batchSize)
                for event in batch {
                    track(event)
                }
                return batch.count
            }
        }

        """
}
