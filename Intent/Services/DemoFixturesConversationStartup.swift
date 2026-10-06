import Foundation

extension DemoFixtures {
    /// Uniform rows isolate entry positioning from tool hydration and footer
    /// resizing. Only explicit UI-test launches use this long unread transcript.
    static func startupTranscriptRequested(by arguments: [String]) -> Bool {
        arguments.contains("--demo-startup-transcript")
    }

    static var usesStartupTranscript: Bool { startupTranscriptRequested(by: ProcessInfo.processInfo.arguments) }
    static let startupSeenMessageId = "startup-row-25"
    private static let startupRowCount = 50

    #if DEBUG
    /// Withhold snapshots, not ACKs, to demonstrate receiving and timeout/retry
    /// feedback. Once the file exists, the next subscription serves its snapshot.
    static func startupSnapshotIsHeld(for method: String, params: [String: Any], arguments: [String]) -> Bool {
        guard method == "chat.subscribe", params["agentId"] as? String == longConversationAgentId,
              let file = triggerFile(from: arguments, prefix: "--demo-chat-delivery-trigger-file=") else { return false }
        return !FileManager.default.fileExists(atPath: file.path)
    }
    #endif

    static var startupTranscriptMessages: [[String: Any]] {
        (0..<startupRowCount).map { index in
            [
                "id": "startup-row-\(index)", "agentId": longConversationAgentId, "role": "assistant",
                "contentBlocks": [
                    [
                        "id": "startup-text-\(index)", "type": "text",
                        "text": "Startup row \(index). This paragraph keeps the transcript visible while agent details arrive."
                    ]
                ]
            ]
        }
    }

    static func startupResponseGate(for method: String, params: [String: Any], arguments: [String]) -> ResponseGate? {
        guard params["agentId"] as? String == longConversationAgentId else { return nil }
        let prefix: String
        switch method {
        case "agent.get": prefix = "--demo-agent-detail-trigger-file="
        case "chat.subscribe": prefix = "--demo-chat-snapshot-trigger-file="
        default: return nil
        }
        return arguments
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .last { !$0.isEmpty }
            .map { .triggerFile(URL(fileURLWithPath: $0)) }
    }
}
