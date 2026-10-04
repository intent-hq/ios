import ImageIO
@testable import Intent
import SwiftUI
import Testing
import UIKit
import UniformTypeIdentifiers

@Suite(.serialized)
@MainActor
struct ComposerDraftBindingTests {
    @Test(arguments: [(false, false), (false, true), (true, false), (true, true)], 1...16)
    func pastedImagesPreserveDraftAndReachSendOrQueue(route: (Bool, Bool), fixture: Int) async throws {
        let (workspaceDesign, queue) = route
        let orientation = (fixture - 1) % 8 + 1
        let large = fixture > 8
        let connection = FakeConnectionManager()
        connection.responseMap["agent.sendMessage"] = ["success": true, "queued": false]
        connection.responseMap["agent.queueMessage"] = ["queuedMessage": ["id": "pasted", "content": "Keep my draft"]]
        connection.responseMap["file.placeAttachment"] = [
            "attachmentId": "pasted-image", "fileName": "image.jpg", "mimeType": "image/jpeg", "size": 1,
            "path": ".intent/attachments/pasted-image/image.jpg"
        ]
        let model = makeModel(connection: connection, workspaceId: workspaceDesign ? UUID().uuidString : Workspace.chiefWorkspaceId)
        model.messageText = "Keep my draft"
        let jpeg = try orientedPhotoData(orientation: orientation, large: large)
        let view = MessageInputView(viewModel: model, store: model.store, usesWorkspaceDesign: workspaceDesign)
        try await SyntheticBadgeHost.render(view, width: 390, height: 250) { root, _ in
            try pastePhoto(in: root, model: model, jpeg: jpeg, orientation: orientation, large: large)
        }
        // Removing a pasted preview must leave only one outbound image block.
        model.removeImage(at: 1)
        if queue { await model.queueMessage(model.messageText) } else { await model.sendMessage(model.messageText) }
        let requests = connection.paramsForMethod(queue ? "agent.queueMessage" : "agent.sendMessage")
        let params = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(params["content"] as? String == "Keep my draft")
        let blocks = try #require(params["imageBlocks"] as? [[String: Any]])
        #expect(blocks.count == 1)
        #expect(blocks[0]["mimeType"] as? String == "image/jpeg")
        let encoded: String
        if workspaceDesign {
            #expect(blocks[0]["attachmentId"] as? String == "pasted-image")
            #expect(blocks[0]["data"] == nil)
            let placement = try #require(connection.paramsForMethod("file.placeAttachment").first)
            encoded = try #require(placement["data"] as? String)
        } else {
            #expect(!connection.requestLog.contains { $0.method.hasPrefix("file.") })
            encoded = try #require(blocks[0]["data"] as? String)
        }
        let data = try #require(Data(base64Encoded: encoded))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        // Host thumbnails decode raw pixels and discard EXIF. Both these pixels
        // and UIKit's metadata-aware display must match the original preview.
        let pixels = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        try expectPhotoPixels(pixels, orientation: orientation, stage: "outgoing", large: large)
        let decoded = try #require(UIImage(data: data))
        #expect(decoded.imageOrientation == .up, "Outgoing pixels must not depend on an EXIF transform")
        #expect(model.pendingImages.isEmpty)
        #expect(model.imagePlacementError == nil)
    }

    @Test(arguments: [false, true], ["unreadable", "unavailable", "tooMany", "tooLarge"])
    func rejectedImagePasteKeepsTheWholeDraft(workspaceDesign: Bool, rejection: String) async throws {
        let model = makeModel()
        model.messageText = "Keep everything"
        let png = try pasteImageData()
        let existing = try #require(UIImage(data: png))
        model.addImage(existing)
        let view = MessageInputView(viewModel: model, store: model.store, usesWorkspaceDesign: workspaceDesign)
        try await SyntheticBadgeHost.render(view, width: 390, height: 250) { root, _ in
            let editor = try #require(textView(in: root))
            let pasteboard = ImagePasteboardFixture()
            editor.imagePasteboard = pasteboard.source
            model.attachmentPipeline.imagePasteboard = pasteboard.source
            editor.selectedRange = NSRange(location: 0, length: 4)
            switch rejection {
            case "tooMany":
                pasteboard.items = Array(
                    repeating: [UTType.png.identifier: png], count: Constants.Conversation.Composer.maximumImageSelectionCount
                )
            case "tooLarge":
                pasteboard.items = [[UTType.png.identifier: Data(count: ConversationAttachmentPipeline.maxImageReferenceBytes + 1)]]
            case "unavailable":
                pasteboard.items = [[UTType.png.identifier: NSNull()]]
            default:
                pasteboard.items = [[UTType.png.identifier: png], [UTType.png.identifier: Data("not an image".utf8)]]
            }
            editor.paste(nil)
            #expect(model.pendingImages.count == 1)
            #expect(model.pendingImages.first === existing)
            let error = try #require(model.imagePlacementError)
            #expect(error.contains(rejection == "tooMany" ? "up to" : rejection == "tooLarge" ? "too large" : "Could not read"))
            #expect(model.messageText == "Keep everything")
            #expect(editor.text == model.messageText)
            #expect(editor.selectedRange == NSRange(location: 0, length: 4))
            pasteboard.items = [[UTType.png.identifier: png]]
            editor.paste(nil)
            #expect(model.pendingImages.count == 2, "a rejected paste must remain recoverable")
            #expect(model.imagePlacementError == nil)
        }
    }

    @Test
    func textPasteDelegatesInsertionWithoutAddingImages() {
        let model = makeModel()
        model.messageText = "abc"
        let adapter = SubmittableTextView(
            text: Binding(get: { model.messageText }, set: { model.messageText = $0 }),
            isFocused: .constant(false),
            onSubmit: {},
            onPasteImages: model.pasteImages
        )
        let coordinator = adapter.makeCoordinator()
        let editor = TextPasteKeyCommandTextView()
        editor.imagePasteboard = ImagePasteboardFixture().source
        editor.pastedText = "hello\nworld"
        editor.delegate = coordinator
        editor.onPasteImages = model.pasteImages
        editor.text = model.messageText
        editor.selectedRange = NSRange(location: 1, length: 1)
        editor.paste(nil)
        #expect(editor.text == "ahello\nworldc")
        #expect(model.messageText == editor.text)
        #expect(model.pendingImages.isEmpty)
        #expect(model.imagePlacementError == nil)
    }

    @Test(arguments: [false, true], [DynamicTypeSize.large, .accessibility5])
    func editsReachTheDraftBeforeAnotherRender(workspaceDesign: Bool, category: DynamicTypeSize) async throws {
        let model = makeModel()
        let prefix = "An accessible draft"
        model.messageText = prefix
        let view = MessageInputView(viewModel: model, store: model.store, usesWorkspaceDesign: workspaceDesign)
            .environment(\.dynamicTypeSize, category)
        try await SyntheticBadgeHost.render(view, width: 390, height: 250) { root, _ in
            let editor = try #require(textView(in: root))
            #expect(editor.text == prefix)
            editor.selectedRange = NSRange(location: prefix.utf16.count, length: 0)

            // Deliver an input burst without allowing SwiftUI's deferred change
            // callbacks to run between edits. The model must own every edit now,
            // so a later render cannot echo an older draft into the editor.
            for part in [" with e", "nough text to wrap onto multiple lines"] {
                editor.insertText(part)
                #expect(model.messageText == editor.text)
            }
            #expect(model.messageText == "An accessible draft with enough text to wrap onto multiple lines")

            editor.selectedRange = NSRange(location: prefix.utf16.count, length: " with e".utf16.count)
            editor.insertText(" WITH E")
            #expect(model.messageText == "An accessible draft WITH Enough text to wrap onto multiple lines")
            #expect(editor.selectedRange == NSRange(location: "An accessible draft WITH E".utf16.count, length: 0))
        }
    }

    @Test
    func queuedRenderCannotOverwriteAnEditReceivedBeforeItRuns() async {
        let model = makeModel()
        model.messageText = "An accessible draf"
        let adapter = SubmittableTextView(
            text: Binding(get: { model.messageText }, set: { model.messageText = $0 }),
            isFocused: .constant(false)
        ) {}
        let coordinator = adapter.makeCoordinator()
        let editor = KeyCommandTextView()
        editor.delegate = coordinator
        editor.text = model.messageText
        editor.selectedRange = NSRange(location: model.messageText.utf16.count, length: 0)

        coordinator.synchronizeText(in: editor)
        editor.insertText("t")
        let selection = editor.selectedRange
        await drainMainQueue()
        #expect(editor.text == "An accessible draft")
        #expect(model.messageText == "An accessible draft")
        #expect(editor.selectedRange == selection)
        editor.insertText(" with enough text to wrap onto multiple lines")
        #expect(editor.text == "An accessible draft with enough text to wrap onto multiple lines")
        #expect(model.messageText == editor.text)
    }

    @Test
    func externalDraftReplacementAndClearingReachTheEditor() async {
        let model = makeModel()
        model.messageText = "Restored draft"
        var heights: [CGFloat] = []
        let adapter = SubmittableTextView(
            text: Binding(get: { model.messageText }, set: { model.messageText = $0 }),
            isFocused: .constant(false),
            onSubmit: {},
            onHeightChange: { heights.append($0) }
        )
        let coordinator = adapter.makeCoordinator()
        let editor = KeyCommandTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        editor.delegate = coordinator
        editor.text = model.messageText
        coordinator.synchronizeText(in: editor)
        model.messageText = "Recovered after a failed send"
        await drainMainQueue()
        #expect(editor.text == "Recovered after a failed send")
        #expect(!heights.isEmpty)
        model.messageText = ""
        coordinator.synchronizeText(in: editor)
        await drainMainQueue()
        #expect(editor.text.isEmpty)
        editor.insertText("Next draft")
        #expect(model.messageText == "Next draft")
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func makeModel(
        connection: FakeConnectionManager = FakeConnectionManager(),
        workspaceId: String = UUID().uuidString
    ) -> ConversationViewModel {
        ConversationViewModel(
            agentId: UUID().uuidString,
            workspaceId: workspaceId,
            agentName: "Composer regression",
            connection: connection,
            uploadService: AttachmentUploadService(connection: connection),
            optionsStore: CreationOptionsStore(connectionManager: connection)
        )
    }

    private func pastePhoto(in root: UIView, model: ConversationViewModel, jpeg: Data, orientation: Int, large: Bool) throws {
        let editor = try #require(textView(in: root))
        editor.selectedRange = NSRange(location: 0, length: 4)
        // Multiple representations of one item must not duplicate the image.
        let pasteboard = ImagePasteboardFixture(items: [
            [UTType.jpeg.identifier: jpeg, UTType.utf8PlainText.identifier: "Do not replace the draft"],
            [UTType.jpeg.identifier: jpeg]
        ])
        editor.imagePasteboard = pasteboard.source
        model.attachmentPipeline.imagePasteboard = pasteboard.source
        #expect(editor.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
        #expect(pasteboard.readCount == 0, "Paste availability must not read clipboard contents")
        editor.paste(nil)
        try #require(model.pendingImages.count == 2, "Paste must reach the composer's attachment owner")
        #expect(pasteboard.readCount == 2)
        let preview = try #require(model.pendingImages.first)
        let format = UIGraphicsImageRendererFormat()
        format.scale = preview.scale
        let rendered = UIGraphicsImageRenderer(size: preview.size, format: format).image { _ in
            preview.draw(at: .zero)
        }
        try expectPhotoPixels(#require(rendered.cgImage), orientation: orientation, stage: "preview", large: large)
        #expect(model.messageText == "Keep my draft")
        #expect(editor.text == model.messageText)
        #expect(editor.selectedRange == NSRange(location: 0, length: 4))
        editor.isEditable = false
        #expect(!editor.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
        editor.paste(nil)
        #expect(model.pendingImages.count == 2)
        #expect(pasteboard.readCount == 2, "Disabled Paste must not read clipboard contents")
    }

    private func orientedPhotoData(orientation: Int, large: Bool) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let halfWidth = large ? 1536 : 48
        let halfHeight = large ? 1024 : 32
        let photo = UIGraphicsImageRenderer(size: CGSize(width: halfWidth * 2, height: halfHeight * 2), format: format).image { context in
            for (index, color) in [UIColor.red, .green, .blue, .yellow].enumerated() {
                color.setFill()
                context.fill(CGRect(x: (index % 2) * halfWidth, y: (index / 2) * halfHeight, width: halfWidth, height: halfHeight))
            }
        }
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(photo.cgImage), [
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 1
        ] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func expectPhotoPixels(_ image: CGImage, orientation: Int, stage: String, large: Bool) throws {
        let width = large ? (stage == "preview" ? 3072 : 2048) : 96
        let height = large ? (stage == "preview" ? 2048 : 1365) : 64
        #expect(image.width == (orientation <= 4 ? width : height), "\(stage) width, EXIF \(orientation)")
        #expect(image.height == (orientation <= 4 ? height : width), "\(stage) height, EXIF \(orientation)")
        // Independent EXIF corner expectations: top-left, top-right, bottom-left,
        // bottom-right, where the untransformed fixture is red/green/blue/yellow.
        let corners = [
            [0, 1, 2, 3], [1, 0, 3, 2], [3, 2, 1, 0], [2, 3, 0, 1],
            [0, 2, 1, 3], [2, 0, 3, 1], [3, 1, 2, 0], [1, 3, 0, 2]
        ][orientation - 1]
        let palette = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0]]
        for (index, corner) in corners.enumerated() {
            let rect = CGRect(
                x: (index.isMultiple(of: 2) ? 1 : 3) * image.width / 4,
                y: (index < 2 ? 1 : 3) * image.height / 4,
                width: 1,
                height: 1
            )
            let sample = try #require(image.cropping(to: rect))
            var pixel = [UInt8](repeating: 0, count: 4)
            try pixel.withUnsafeMutableBytes { bytes in
                let context = try #require(CGContext(
                    data: bytes.baseAddress,
                    width: 1,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            for channel in 0..<3 {
                #expect(abs(Int(pixel[channel]) - palette[corner][channel]) < 32, "\(stage) corner \(index), EXIF \(orientation)")
            }
        }
    }

    private func pasteImageData() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        return try #require(image.pngData())
    }

    private func textView(in view: UIView) -> KeyCommandTextView? {
        if let editor = view as? KeyCommandTextView { return editor }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }
}
