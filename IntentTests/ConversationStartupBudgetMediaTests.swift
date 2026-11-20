import Foundation
@testable import Intent
import Testing

extension ConversationStartupBudgetTests {
    @Test func renderedAttachmentAndAssetCostsIncludeCachedSecondConsumers() async throws {
        let fixture = ConversationBudgetFixture()
        defer { fixture.startup.stop() }
        let connection = fixture.connection
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let bytes = try #require(Data(base64Encoded: png))
        connection.responseMap["file.getAttachmentInfo"] = ["path": "images/budget.png", "exists": true]
        connection.responseMap["file.readChunk"] = ["content": png, "bytesRead": bytes.count, "size": bytes.count]
        connection.responseMap["note.readAsset"] = ["assetId": "budget.png", "mimeType": "image/png", "data": png, "sizeKb": 1]
        await fixture.startup.makeViewModel().load()
        let render = connection.checkpoint
        let attachment = fixture.startup.session.attachmentImageLoader
        let files = fixture.startup.session.workspaceFileImageLoader
        _ = try await attachment.image(workspaceId: ConversationStartupFixture.workspaceId, attachmentId: "budget-attachment")
        _ = try await files.assetImage(workspaceId: ConversationStartupFixture.workspaceId, assetId: "budget.png")
        _ = try await attachment.image(workspaceId: ConversationStartupFixture.workspaceId, attachmentId: "budget-attachment")
        _ = try await files.assetImage(workspaceId: ConversationStartupFixture.workspaceId, assetId: "budget.png")
        let media = connection.traffic(since: render)
        #expect(media.methodCounts == ["file.getAttachmentInfo": 1, "file.readChunk": 1, "note.readAsset": 1])
        #expect(media.calls("file.readChunk").first?.params["length"] as? Int == 4 * 1024 * 1024)
        try ConversationBudgetEvidence.emit("rendered-media", media)
        try await fixture.stopAndWait()
        try ConversationBudgetEvidence.emit("rendered-media-complete", connection.traffic())
    }
}
