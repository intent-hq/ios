#if DEBUG
import Foundation

extension DemoFixtures {
    static let inlineImageAgentId = "demo-agent-implementor"
    static let inlineImageSuggestedPrompts = ["Show the recording screen.", "Show the mobile layout."]

    static func inlineImageConversationRequested(by arguments: [String]) -> Bool {
        DemoMode.demoDataRequested(by: arguments) && arguments.contains("--demo-inline-images")
    }

    static var inlineImageConversationMessages: [[String: Any]] {
        if LaunchOptions.current.contains("--demo-user-image-block") {
            return imageBlockConversation(role: "user")
        }
        if LaunchOptions.current.contains("--demo-assistant-image-block") {
            return imageBlockConversation(role: "assistant")
        }
        let response = LaunchOptions.current.contains("--demo-inline-image-keyboard")
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
        let missingURL = "workspace-asset://\(statusImageWorkspaceId)/missing-preview.png"
        return [
            "Before the saved image.",
            inlineImageSavedPreviewText,
            "After the saved image, before the missing image.",
            "Missing preview:  \n![Missing settings preview](\(missingURL))",
            "After the missing image. The response is still readable.",
            "<!-- suggested-prompts\n<!-- suggested-prompts\n"
                + inlineImageSuggestedPrompts.joined(separator: "\n") + "\n-->"
        ].joined(separator: "\n\n")
    }
}
#endif
