@testable import Intent
import SwiftUI
import Testing
import UIKit
import UniformTypeIdentifiers

@MainActor
@Suite(.serialized)
struct WorkspaceCreationImagesTests {
    private func png() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6), format: format)
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        }
        return try #require(image.pngData())
    }

    @Test func importGatesImmediatelyAndEncodesDecodableJPEG() async throws {
        let draft = WorkspaceCreationImages()
        let data = try png()
        let task = try #require(draft.add([{ data }]))
        #expect(draft.isImporting)
        let provider = ProviderInfo(id: "auggie", authenticated: .signedIn)
        #expect(CreateWorkspaceView.isCreateDisabled(
            isCreating: false,
            isLoadingProviders: false,
            providers: [provider],
            selectedProvider: provider,
            isImportingImages: draft.isImporting
        ))
        await task.value
        #expect(!draft.isImporting)
        let image = try #require(draft.images.first)
        let encoded = try #require(image.block["data"] as? String)
        #expect(UIImage(data: try #require(Data(base64Encoded: encoded)))?.size == CGSize(width: 8, height: 6))
        #expect(image.block["mimeType"] as? String == "image/jpeg")
        #expect(draft.errorMessage == nil)
    }

    @Test(arguments: [ConnectionPrincipal.HostRole.member, .owner])
    func finishingImageImportCannotRestoreLostCreationAuthority(role: ConnectionPrincipal.HostRole) async throws {
        let connection = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(connectionManager: connection),
            connection: connection,
            persistence: .ephemeral()
        )
        connection.currentPrincipal = InvitedSessionFixtures.principal(role: role)
        connection.connectionState = .connected
        let draft = WorkspaceCreationImages()
        let provider = ProviderInfo(id: "auggie", authenticated: .signedIn)
        func isCreateDisabled() -> Bool {
            CreateWorkspaceView.isCreateDisabled(
                isCreating: false,
                isLoadingProviders: false,
                providers: [provider],
                selectedProvider: provider,
                allowsCreation: coordinator.canCreateWorkspace,
                isImportingImages: draft.isImporting
            )
        }
        let data = try png()
        let task = try #require(draft.add([{ data }]))
        #expect(coordinator.canCreateWorkspace)
        #expect(draft.isImporting)
        #expect(isCreateDisabled())
        connection.currentPrincipal = InvitedSessionFixtures.principal(role: .guest)
        await task.value
        #expect(!draft.isImporting)
        #expect(draft.images.count == 1)
        #expect(coordinator.shouldDismissWorkspaceCreation)
        #expect(isCreateDisabled())
        connection.currentPrincipal = InvitedSessionFixtures.principal(role: role)
        #expect(!isCreateDisabled())
    }

    @Test func failedBatchPreservesDraftAndRemovalFreesASelectionSlot() async throws {
        let draft = WorkspaceCreationImages()
        let data = try png()
        await draft.add([{ data }])?.value
        let original = try #require(draft.images.first)
        await draft.add([{ data }, { Data("not an image".utf8) }])?.value
        #expect(draft.images.map(\.id) == [original.id])
        #expect(draft.errorMessage != nil)
        #expect(!draft.isImporting)
        let remaining = draft.remainingCount
        draft.remove(original.id)
        #expect(draft.images.isEmpty)
        #expect(draft.remainingCount == remaining + 1)
    }

    @Test func countLimitAndOversizedInputRejectWithoutDroppingExistingImages() async throws {
        let draft = WorkspaceCreationImages()
        let data = try png()
        let loaders: [WorkspaceCreationImages.Loader] = (0..<5).map { _ in { data } }
        await draft.add(loaders)?.value
        #expect(draft.images.count == 5)
        #expect(draft.add([{ data }]) == nil)
        #expect(draft.errorMessage?.contains("Remove") == true)
        let id = try #require(draft.images.first?.id)
        draft.remove(id)
        await draft.add([{ Data(count: WorkspaceCreationImages.maximumSourceBytes + 1) }])?.value
        #expect(draft.images.count == 4)
        #expect(draft.errorMessage?.contains("smaller") == true)
    }

    @Test func cancelledImportCannotOverwriteANewerBatch() async throws {
        let draft = WorkspaceCreationImages()
        let data = try png()
        var resume: CheckedContinuation<Data, Never>?
        let old = try #require(draft.add([
            { await withCheckedContinuation { resume = $0 } }
        ]))
        while resume == nil { await Task.yield() }
        draft.cancelImport()
        let fresh = try #require(draft.add([{ data }]))
        resume?.resume(returning: data)
        await old.value
        await fresh.value
        #expect(draft.images.count == 1)
        #expect(!draft.isImporting)
        #expect(draft.errorMessage == nil)
    }

    @Test func fileSelectionDecodesImagesRejectsNonImagesAndCancellationKeepsDraft() async throws {
        let draft = WorkspaceCreationImages()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try png().write(to: url)
        draft.addFiles(.success([url]))
        try await waitForImport(draft)
        #expect(draft.images.count == 1)
        let id = try #require(draft.images.first?.id)
        draft.addPhotos([])
        draft.addFiles(.failure(CocoaError(.userCancelled)))
        #expect(draft.images.map(\.id) == [id])
        #expect(draft.errorMessage == nil)
        let textURL = url.deletingPathExtension().appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: textURL) }
        try Data("text".utf8).write(to: textURL)
        draft.addFiles(.success([textURL]))
        try await waitForImport(draft)
        #expect(draft.images.map(\.id) == [id])
        #expect(draft.errorMessage != nil)
    }

    @Test func nativePasteActionAddsAnImageWithoutReplacingSelectedPromptText() async throws {
        let draft = WorkspaceCreationImages()
        let view = WorkspacePromptUITextView()
        view.text = "Keep my prompt"
        view.selectedRange = NSRange(location: 0, length: 4)
        view.onPasteImages = draft.addPaste
        UIPasteboard.general.setData(try png(), forPasteboardType: UTType.png.identifier)
        defer { UIPasteboard.general.items = [] }
        #expect(view.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
        // Same responder selector dispatched by edit-menu Paste and Command-V.
        view.paste(nil)
        #expect(draft.isImporting)
        try await waitForImport(draft)
        #expect(draft.images.count == 1)
        #expect(view.text == "Keep my prompt")
        #expect(view.selectedRange == NSRange(location: 0, length: 4))
        view.allowsImagePaste = false
        #expect(!view.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
        view.paste(nil)
        #expect(!draft.isImporting)
        #expect(draft.images.count == 1)
    }

    @Test func normalTextPasteReplacesSelectionAndReturnInsertsNewline() async throws {
        let view = WorkspacePromptUITextView()
        view.text = "abc"
        view.selectedRange = NSRange(location: 1, length: 1)
        var imported = false
        view.onPasteImages = { imported = true }
        UIPasteboard.general.string = "hello\nworld"
        defer { UIPasteboard.general.items = [] }
        view.paste(nil)
        // UIKit may finish its item-provider insertion on the next run loop.
        for _ in 0..<100 where view.text == "abc" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(view.text == "ahello\nworldc")
        view.insertText("\n")
        #expect(view.text == "ahello\nworld\nc")
        #expect(!imported)
    }

    @Test(arguments: ["", "  Use this screenshot  "])
    func imageOnlyAndCombinedInitialPayloadsKeepBytes(message: String) async throws {
        let draft = WorkspaceCreationImages()
        let data = try png()
        await draft.add([{ data }])?.value
        let image = try #require(draft.images.first)
        let input = CreateWorkspaceView.InitialAgentInput(
            specialist: nil, provider: nil, model: nil, message: message, imageBlocks: [image.block]
        )
        let params = CreateWorkspaceView.buildCreateWorkspaceParams(
            githubUrl: "https://github.com/test/repo", baseRef: "main", idempotencyKey: "retry-key", initialAgent: input
        )
        let agent = try #require(params["initialAgent"] as? [String: Any])
        let blocks = try #require(agent["imageBlocks"] as? [[String: String]])
        #expect(blocks.count == 1)
        #expect(blocks[0]["type"] == "image")
        #expect(Data(base64Encoded: try #require(blocks[0]["data"])) == image.jpeg)
        #expect(agent["prompt"] as? String == (message.isEmpty ? nil : "Use this screenshot"))
        #expect(agent["fileBlocks"] == nil)
        #expect(blocks[0]["attachmentId"] == nil)
        try WorkspaceCreationImages.validateRequest(params)
        #expect(params["idempotencyKey"] as? String == "retry-key")
        #expect(draft.images.map(\.id) == [image.id])
    }

    @Test func fullRequestLimitIncludesEscapedJSONAndEnvelopeNotJustSourceBytes() throws {
        let limit = WorkspaceCreationImages.maximumRequestBytes
        try WorkspaceCreationImages.validateRequest(["prompt": String(repeating: "a", count: limit - 1024)])
        #expect(throws: WorkspaceCreationImages.ImportError.self) {
            try WorkspaceCreationImages.validateRequest(["prompt": String(repeating: "a", count: limit)])
        }
        // Quotes are one source byte but two encoded bytes; counting raw text fails.
        #expect(throws: WorkspaceCreationImages.ImportError.self) {
            try WorkspaceCreationImages.validateRequest(["prompt": String(repeating: "\"", count: limit / 2)])
        }
    }

    private func waitForImport(_ draft: WorkspaceCreationImages) async throws {
        for _ in 0..<200 where draft.isImporting { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!draft.isImporting, "Image import did not finish")
    }
}
