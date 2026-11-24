#if DEBUG
import UIKit

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
        if LaunchOptions.current.contains("--demo-image-gallery") {
            return imageGalleryConversation
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

    private static var imageGalleryConversation: [[String: Any]] {
        func imageBlock(_ index: Int) -> [String: Any] {
            ["type": "image", "data": galleryImagePNG(index).base64EncodedString(), "mimeType": "image/png"]
        }
        return [
            [
                "id": "demo-image-gallery-user",
                "role": "user",
                "timestamp": transcriptIso(minutesAgo: 2),
                "contentBlocks": [
                    ["type": "text", "text": "Two attached screenshots."],
                    imageBlock(0),
                    imageBlock(1)
                ]
            ],
            [
                "id": "demo-image-gallery-assistant",
                "role": "assistant",
                "timestamp": transcriptIso(minutesAgo: 1),
                "contentBlocks": [
                    [
                        "type": "text",
                        "text": "Here is the saved preview.\n\n"
                            + "![Saved preview](workspace-asset://\(statusImageWorkspaceId)/\(statusImageAssetId))"
                    ],
                    imageBlock(2)
                ]
            ]
        ]
    }

    // swiftlint:disable no_magic_numbers
    private static func galleryImagePNG(_ index: Int) -> Data {
        let size = CGSize(width: 600, height: 400)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let colors: [UIColor] = [.systemBlue, .systemGreen, .systemOrange]
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            colors[index % colors.count].setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let label = NSAttributedString(string: "\(index + 1)", attributes: [
                .font: UIFont.systemFont(ofSize: 180, weight: .bold),
                .foregroundColor: UIColor.white
            ])
            let labelSize = label.size()
            label.draw(at: CGPoint(x: (size.width - labelSize.width) / 2, y: (size.height - labelSize.height) / 2))
        }
    }
    // swiftlint:enable no_magic_numbers

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
