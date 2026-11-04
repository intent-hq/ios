#if DEBUG
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
            ["name": "Sources", "type": "directory"],
            ["name": "Tests", "type": "directory"],
            ["name": "Web", "type": "directory"],
            ["name": "docs", "type": "directory"],
            ["name": ".gitignore", "type": "file"]
        ],
        "Sources": [
            ["name": "Analytics.swift", "type": "file"],
            ["name": "Analytics", "type": "directory"]
        ],
        "Sources/Analytics": [["name": "Events.swift", "type": "file"]],
        "Tests": [["name": "AnalyticsTests.swift", "type": "file"]],
        "Web": [["name": "collector.ts", "type": "file"]],
        "docs": []
    ]

    private static let contents = [
        "README.md": "# Usage analytics\n\nA dashboard for workspace activity.\n",
        ".gitignore": ".build/\n.DS_Store\n",
        "Sources/Analytics.swift": "struct Analytics {\n    let enabled = true\n}\n",
        "Sources/Analytics/Events.swift": "enum Event {\n    case workspaceOpened\n}\n",
        "Tests/AnalyticsTests.swift": "import Testing\n\n@Test func analyticsIsEnabled() {\n    #expect(Analytics().enabled)\n}\n",
        "Web/collector.ts": """
            export interface AnalyticsEvent {
              name: string;
              workspaceId: string;
            }

            export function collect(events: AnalyticsEvent[]): Map<string, number> {
              const counts = new Map<string, number>();
              for (const event of events) {
                counts.set(event.name, (counts.get(event.name) ?? 0) + 1);
              }
              return counts;
            }

            """
    ]
}
#endif
