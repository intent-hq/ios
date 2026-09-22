import Foundation
@testable import Intent
import Testing

@MainActor
struct DemoInlineImageFixtureTests {
    @Test func imageResponseRequiresBothDemoArguments() {
        #expect(!DemoFixtures.inlineImageConversationRequested(by: []))
        #expect(!DemoFixtures.inlineImageConversationRequested(by: ["--demo-data"]))
        #expect(!DemoFixtures.inlineImageConversationRequested(by: ["--demo-inline-images"]))
        #expect(DemoFixtures.inlineImageConversationRequested(by: ["--demo-data", "--demo-inline-images"]))
    }

    @Test func completeResponseUsesOneAssistantTextBlockAndLocalAssets() throws {
        let messages = DemoFixtures.inlineImageConversationMessages.compactMap { ConversationMessage.parseMessage($0) }
        #expect(messages.count == 2)
        let assistant = try #require(messages.last)
        #expect(assistant.role == .assistant)
        #expect(assistant.contentBlocks.count == 1)
        let block = try #require(assistant.contentBlocks.first)
        #expect(block.type == .text)
        let text = try #require(block.resolvedText)
        #expect(text == DemoFixtures.inlineImageResponseText)
        #expect(!text.contains("https://"))
        #expect(!text.contains("http://"))

        let imagePattern = /!\[[^\]]*\]\(([^)]+)\)/
        let links = try text.matches(of: imagePattern).map { match in
            let url = try #require(URL(string: String(match.output.1)))
            return try #require(WorkspaceAssetLink.parse(url))
        }
        #expect(links.count == 2)
        let saved = try #require(links.first)
        let missing = try #require(links.last)
        let savedResponse = try assetResponse(saved)
        let base64 = try #require(savedResponse["data"] as? String)
        let bytes = try #require(Data(base64Encoded: base64))
        #expect(WorkspaceFileImageLoader.decodeImage(bytes) != nil)
        #expect(try assetResponse(missing).isEmpty)
    }

    private func assetResponse(_ link: WorkspaceAssetLink) throws -> [String: Any] {
        try #require(DemoFixtures.response(
            for: "note.readAsset",
            params: ["workspaceId": link.workspaceId, "asset": link.assetId]
        ) as? [String: Any])
    }
}
