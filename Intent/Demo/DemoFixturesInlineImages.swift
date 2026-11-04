#if DEBUG
import Foundation

extension DemoFixtures {
    static let inlineImageAgentId = "demo-agent-implementor"
    static let inlineImageSuggestedPrompts = ["Show the recording screen.", "Show the mobile layout."]

    /// Opt-in so existing demo screenshots and transcript fixtures stay unchanged.
    static func inlineImageConversationRequested(by arguments: [String]) -> Bool {
        DemoMode.demoDataRequested(by: arguments) && arguments.contains("--demo-inline-images")
    }

    /// One real assistant text block, served through both chat.subscribe and
    /// agent.getConversation. The existing note.readAsset fixture supplies the
    /// PNG; the unknown asset returns an empty payload. Neither needs a network.
    /// The linked workspace intentionally differs from the conversation's.
    static var inlineImageConversationMessages: [[String: Any]] {
        if ProcessInfo.processInfo.arguments.contains("--demo-user-image-block") {
            return imageBlockConversation(role: "user")
        }
        if ProcessInfo.processInfo.arguments.contains("--demo-assistant-image-block") {
            return imageBlockConversation(role: "assistant")
        }
        let response = ProcessInfo.processInfo.arguments.contains("--demo-inline-image-keyboard")
            ? inlineImageSavedPreviewText : inlineImageResponseText
        return [
            [
                "id": "demo-inline-images-user",
                "role": "user",
                "timestamp": transcriptIso(minutesAgo: 2),
                "contentBlocks": [["type": "text", "text": "Show the saved previews."]]
            ],
            [
                "id": "demo-inline-images-assistant",
                "role": "assistant",
                "timestamp": transcriptIso(minutesAgo: 1),
                "contentBlocks": [["type": "text", "text": response]]
            ]
        ]
    }

    private static func imageBlockConversation(role: String) -> [[String: Any]] {
        [
            [
                "id": "demo-image-block-\(role)",
                "role": role,
                "timestamp": transcriptIso(minutesAgo: 1),
                "contentBlocks": [
                    ["type": "text", "text": "An attached screenshot."],
                    ["type": "image", "data": statusImagePNG.base64EncodedString(), "mimeType": "image/png"]
                ]
            ]
        ]
    }

    private static var inlineImageSavedPreviewText: String {
        let savedURL = "workspace-asset://\(statusImageWorkspaceId)/\(statusImageAssetId)"
        return "Saved preview:  \n![Saved settings preview](\(savedURL))"
    }

    static var inlineImageResponseText: String {
        // Explicit hard breaks keep each caption and its attachment in one
        // paragraph, whose real layout bounds are observable by XCUITest even
        // though Textual draws the attachment body as a Canvas symbol.
        let missingURL = "workspace-asset://\(statusImageWorkspaceId)/missing-preview.png"
        return [
            "Before the saved image.",
            inlineImageSavedPreviewText,
            "After the saved image, before the missing image.",
            "Missing preview:  \n![Missing settings preview](\(missingURL))",
            "After the missing image. The response is still readable.",
            // Reproduces a raw opener beside otherwise valid prompt buttons.
            // The original report has no raw payload; this is a controlled case.
            "<!-- suggested-prompts\n<!-- suggested-prompts\n"
                + inlineImageSuggestedPrompts.joined(separator: "\n") + "\n-->"
        ].joined(separator: "\n\n")
    }
}
#endif
