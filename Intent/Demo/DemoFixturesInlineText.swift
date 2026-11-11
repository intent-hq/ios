#if DEBUG
import Foundation

extension DemoFixtures {
    /// Opt-in so existing demo transcripts and screenshots stay unchanged.
    static var usesInlineText: Bool {
        let arguments = LaunchOptions.current.arguments
        return DemoMode.demoDataRequested(by: arguments) && arguments.contains("--demo-inline-text")
    }

    private static let inlineTextPath = "docs/Demo notes.txt"
    /// Linked as a relative path, the way agents often write report links.
    private static let inlineHTMLPath = "reports/Demo report.html"

    static var inlineTextMessages: [[String: Any]] {
        let text = [
            "Here are the project notes.",
            "[Open the text notes](intent://local/file/docs/Demo%20notes.txt)",
            "[Open the missing text file](intent://local/file/docs/Missing%20notes.txt)",
            "[Open the HTML report](reports/Demo%20report.html)",
            // Links the app can't open: each tap shows a message instead of doing nothing.
            "[Open the workspace settings](intent://local/settings)",
            "[Open the signed-in preview](http://user@localhost:3000)",
            "The notes are ready to review and share."
        ].joined(separator: "\n\n")
        return [
            [
                "id": "demo-text-assistant", "role": "assistant", "timestamp": transcriptIso(minutesAgo: 1),
                "contentBlocks": [["type": "text", "text": text]]
            ]
        ]
    }

    static func inlineTextResponse(for method: String, params: [String: Any]) -> Any? {
        guard usesInlineText, method == "file.readChunk",
              params["workspaceId"] as? String == "demo-ws-dashboard",
              let bytes = inlineFiles[params["path"] as? String ?? ""] else { return nil }
        let offset = params["offset"] as? Int ?? 0
        let length = params["length"] as? Int ?? 0
        guard offset >= 0, offset <= bytes.count, length > 0 else { return [:] }
        let chunk = bytes.dropFirst(offset).prefix(length)
        return [
            "content": chunk.base64EncodedString(), "bytesRead": chunk.count,
            "size": bytes.count
        ]
    }

    private static var inlineFiles: [String: Data] {
        [inlineTextPath: inlineTextBytes, inlineHTMLPath: inlineHTMLBytes]
    }

    private static let inlineHTMLBytes = Data("""
    <!doctype html>
    <html><head><meta charset="utf-8"><title>Demo report</title></head>
    <body>
    <h1>Usage analytics report</h1>
    <p>Daily active users rose 12% this week.</p>
    </body></html>
    """.utf8)

    private static let inlineTextBytes = Data("""
    Intent project notes

    A small UTF-8 text file shared in chat.

    Café review — ready to share.

    This deliberately long line wraps within the viewer so the entire note stays readable without horizontal scrolling, even on a narrow phone screen.

    Review checklist
    1. Read the notes.
    2. Share the original text file.
    3. Return to the conversation.
    """.utf8)
}
#endif
