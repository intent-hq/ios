import Foundation
@testable import Intent
import PDFKit
import SwiftUI
import Testing
@testable import Textual
import UIKit

extension IntentFileAttachmentLoaderTests {
    @Test(arguments: ["intent://local/file/reports/Review%20notes.pdf", "intent://local/linked/file/reports/Review%20notes.PDF"])
    func pdfEmbedLoadsThumbnailAndPagesFromChunks(_ address: String) async throws {
        let bytes = Self.pdfBytes()
        let midpoint = bytes.count / 2
        let connection = FakeConnectionManager()
        connection.responseQueueMap["file.readChunk"] = [
            Self.pdfChunk(Data(bytes.prefix(midpoint)), size: bytes.count),
            Self.pdfChunk(Data(bytes.suffix(from: midpoint)), size: bytes.count)
        ]
        let fileLoader = WorkspaceFileImageLoader(connection: connection)
        let loader = pdfAttachmentLoader(fileLoader: fileLoader)
        let url = try #require(URL(string: address))
        let attachment = try await loader.resolvedAttachment(for: url, text: "Review", fallback: pdfForbiddenFallback)
        let pdf = try #require(MarkdownTextView.previewPDF(for: attachment))
        #expect(pdf.name == (address.hasSuffix(".PDF") ? "Review notes.PDF" : "Review notes.pdf"))
        #expect(pdf.pageCount == 2)
        #expect(pdf.byteCount == bytes.count)
        #expect(pdf.thumbnail.size.width > 0 && pdf.thumbnail.size.height > 0)
        #expect(try Data(contentsOf: pdf.url) == bytes)
        #expect(PDFDocument(url: pdf.url)?.page(at: 1)?.string?.contains("Second page") == true)
        #expect(MarkdownTextView.lightboxImage(for: attachment) == nil)
        #expect(MarkdownTextView.playbackVideo(for: attachment) == nil)
        let cached = try await loader.resolvedAttachment(for: url, text: "Review", fallback: pdfForbiddenFallback)
        #expect(MarkdownTextView.previewPDF(for: cached) === pdf)
        let requests = connection.paramsForMethod("file.readChunk")
        #expect(requests.count == 2)
        #expect(requests.first?["workspaceId"] as? String == (address.contains("/linked/") ? "linked" : "current"))
        #expect(requests.last?["offset"] as? Int == midpoint)

        let card = try #require(attachment.base as? IntentFilePDFAttachment)
        let rendered = try #require(ImageRenderer(content: card.body).uiImage)
        #expect(rendered.size.width == rendered.size.height)
        #expect(card.sizeThatFits(.init(width: 100, height: nil), in: TextEnvironmentValues()) == CGSize(width: 100, height: 100))
    }

    @Test(arguments: ["missing", "timeout", "corrupt", "oversized", "partial", "no-workspace", "cancelled"], [false, true])
    func failedPDFEmbedShowsPlaceholderAndCanRetry(_ failure: String, explicitWorkspace: Bool) async throws {
        let connection = FakeConnectionManager()
        let bytes = Self.pdfBytes()
        switch failure {
        case "missing": connection.errorMap["file.readChunk"] = URLError(.fileDoesNotExist)
        case "timeout": connection.errorMap["file.readChunk"] = URLError(.timedOut)
        case "cancelled": connection.errorMap["file.readChunk"] = CancellationError()
        case "oversized": connection.responseMap["file.readChunk"] = Self.pdfChunk(bytes, size: WorkspacePDF.maxBytes + 1)
        case "partial": connection.responseMap["file.readChunk"] = Self.pdfChunk(Data(), size: bytes.count)
        default: connection.responseMap["file.readChunk"] = Self.pdfChunk(Data("not a PDF".utf8), size: 9)
        }
        let fileLoader = WorkspaceFileImageLoader(connection: connection)
        let loader = pdfAttachmentLoader(fileLoader: fileLoader, workspaceId: failure == "no-workspace" ? nil : "current")
        let workspace = explicitWorkspace && failure != "no-workspace" ? "linked" : "current"
        let address = workspace == "linked" ? "intent://local/linked/file/report.pdf" : "intent://local/file/report.pdf"
        let url = try #require(URL(string: address))
        let failed = try await loader.resolvedAttachment(for: url, text: "", fallback: pdfForbiddenFallback)
        let placeholder = try #require(failed.base as? IntentFilePDFFailureAttachment)
        #expect(placeholder.name == "report.pdf")
        #expect(MarkdownTextView.previewPDF(for: failed) == nil)
        if failure == "no-workspace" {
            #expect(!placeholder.prepareRetry(using: fileLoader))
            #expect(connection.paramsForMethod("file.readChunk").isEmpty)
            return
        }
        if failure != "cancelled" {
            _ = try await loader.resolvedAttachment(for: url, text: "", fallback: pdfForbiddenFallback)
            #expect(connection.paramsForMethod("file.readChunk").count == 1, "Failures must not refetch on scrolling")
        }
        connection.errorMap["file.readChunk"] = nil
        connection.responseMap["file.readChunk"] = Self.pdfChunk(bytes, size: bytes.count)
        #expect(placeholder.prepareRetry(using: fileLoader))
        let retried = try await loader.resolvedAttachment(for: url, text: "", fallback: pdfForbiddenFallback)
        #expect(MarkdownTextView.previewPDF(for: retried)?.pageCount == 2)
        #expect(connection.paramsForMethod("file.readChunk").count == 2)
        #expect(connection.paramsForMethod("file.readChunk").allSatisfy { $0["workspaceId"] as? String == workspace })
    }

    @Test func pdfSizeLimitRejectsBeforeDecodingOrRequestingMoreChunks() async {
        let connection = FakeConnectionManager()
        connection.responseMap["file.readChunk"] = Self.pdfChunk(Data([0]), size: WorkspacePDF.maxBytes + 1)
        let loader = WorkspaceFileImageLoader(connection: connection)
        await #expect(throws: WorkspaceFileImageLoader.LoadError.fileTooLarge) {
            _ = try await loader.pdf(workspaceId: "ws", path: "large.pdf")
        }
        #expect(connection.paramsForMethod("file.readChunk").count == 1)
    }

    @Test func concurrentPDFRequestsShareDownloadEvenWhenAnAwaiterIsCancelled() async throws {
        let connection = FakeConnectionManager()
        connection.pendingMethods = ["file.readChunk"]
        let loader = WorkspaceFileImageLoader(connection: connection)
        let first = Task { try await loader.pdf(workspaceId: "ws", path: "report.pdf") }
        try await connection.waitForPendingRequests("file.readChunk")
        let secondStarted = TestGate()
        let second = Task {
            secondStarted.open()
            return try await loader.pdf(workspaceId: "ws", path: "report.pdf")
        }
        await secondStarted.wait()
        first.cancel()
        // Do not suspend an unexpected duplicate forever if sharing regresses.
        connection.pendingMethods = []
        let bytes = Self.pdfBytes()
        connection.responseMap["file.readChunk"] = Self.pdfChunk(bytes, size: bytes.count)
        connection.resolvePending("file.readChunk", with: Self.pdfChunk(bytes, size: bytes.count))
        let firstPDF = try await first.value
        let secondPDF = try await second.value
        #expect(firstPDF === secondPDF)
        #expect(connection.paramsForMethod("file.readChunk").count == 1)
    }

    @Test func pdfCacheEvictionKeepsViewerFileUntilLastOwnerReleasesIt() async throws {
        let bytes = Self.pdfBytes()
        let connection = FakeConnectionManager()
        connection.responseMap["file.readChunk"] = Self.pdfChunk(bytes, size: bytes.count)
        let loader = WorkspaceFileImageLoader(connection: connection)
        var viewerOwner: WorkspacePDF? = try await loader.pdf(workspaceId: "ws", path: "first.pdf")
        let url = try #require(viewerOwner?.url)
        for index in 1...8 {
            _ = try await loader.pdf(workspaceId: "ws", path: "report-\(index).pdf")
        }
        #expect(try withExtendedLifetime(viewerOwner) { try Data(contentsOf: url) } == bytes)
        let reloaded = try await loader.pdf(workspaceId: "ws", path: "first.pdf")
        #expect(reloaded.url != url)
        viewerOwner = nil
        try await waitUntil("PDF file removed after viewer releases evicted download") {
            !FileManager.default.fileExists(atPath: url.path)
        }
    }

    /// ios#803: the share sheet must name the original document, not the cache file.
    @Test func pdfSharesUnderOriginalNameWhileCacheKeepsUniqueNameAndCleanup() async throws {
        let bytes = Self.pdfBytes()
        let connection = FakeConnectionManager()
        connection.responseMap["file.readChunk"] = Self.pdfChunk(bytes, size: bytes.count)
        let loader = WorkspaceFileImageLoader(connection: connection)
        var owner: WorkspacePDF? = try await loader.pdf(workspaceId: "ws", path: "docs/Demo brief.pdf")
        let cacheURL = try #require(owner?.url)
        let shareURL = try #require(owner?.shareURL)
        #expect(shareURL.lastPathComponent == "Demo brief.pdf")
        #expect(cacheURL.lastPathComponent.hasPrefix("chat-pdf-"))
        #expect(shareURL != cacheURL)
        #expect(try Data(contentsOf: shareURL) == bytes)
        #expect(try Data(contentsOf: cacheURL) == bytes)
        let shareDirectory = shareURL.deletingLastPathComponent()
        #expect(shareDirectory == WorkspacePDF.shareDirectory(for: cacheURL))
        withExtendedLifetime(owner) {}
        owner = nil
        for index in 1...8 {
            _ = try await loader.pdf(workspaceId: "ws", path: "evict-\(index).pdf")
        }
        try await waitUntil("Cache file and named share copy removed with the PDF") {
            !FileManager.default.fileExists(atPath: cacheURL.path)
                && !FileManager.default.fileExists(atPath: shareDirectory.path)
        }
    }

    @Test(arguments: [
        ("Demo brief.pdf", "Demo brief.pdf"),
        ("Review notes.PDF", "Review notes.PDF"),
        ("  Q3: plan.pdf ", "Q3- plan.pdf"),
        ("a/b\\c\nd.pdf", "a-b-c-d.pdf"),
        ("..hidden.pdf", "hidden.pdf"),
        ("report", "report.pdf"),
        (".pdf", "pdf.pdf"),
        ("   ", "Document.pdf"),
        ("..", "Document.pdf"),
        (String(repeating: "x", count: 300) + ".pdf", String(repeating: "x", count: 200) + ".pdf")
    ])
    func pdfExportFileNameIsASafeSingleComponent(_ name: String, expected: String) {
        #expect(WorkspacePDF.exportFileName(for: name) == expected)
    }

    @Test(arguments: [Data("not a PDF".utf8), Data("%PDF-invalid".utf8)])
    func nonPDFPreparationRejectsAndRemovesTemporaryFile(_ bytes: Data) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-test-\(UUID()).pdf")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: WorkspaceFileImageLoader.LoadError.notAPDF) {
            _ = try await WorkspacePDF.prepare(fileURL: url, name: "report.pdf", byteCount: bytes.count)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func largePDFLoadsAcrossDelayedChunks() async throws {
        let document = try #require(PDFDocument(data: Self.pdfBytes()))
        let payloadSize = 12 * 1024 * 1024
        document.documentAttributes = [PDFDocumentAttribute.subjectAttribute: String(repeating: "x", count: payloadSize)]
        let bytes = try #require(document.dataRepresentation())
        #expect(bytes.count >= payloadSize)
        let connection = SlowPDFConnection(bytes: bytes)
        let loader = WorkspaceFileImageLoader(connection: connection)
        let pdf = try await loader.pdf(workspaceId: "ws", path: "large.pdf")
        #expect(pdf.pageCount == 2)
        #expect(pdf.byteCount == bytes.count)
        #expect(try Data(contentsOf: pdf.url) == bytes)
        #expect(PDFDocument(url: pdf.url)?.page(at: 1)?.string?.contains("Second page") == true)
        #expect(connection.requestLog.count > 1)
        let cached = try await loader.pdf(workspaceId: "ws", path: "large.pdf")
        #expect(cached === pdf)
    }

    @Test(arguments: [3, 1019, 1024])
    func pdfHeaderCanAppearWithinFirstKilobyte(_ prefixLength: Int) async throws {
        let bytes = Data(repeating: 0x20, count: prefixLength) + Self.pdfBytes()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-header-\(UUID()).pdf")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        if prefixLength == 1024 {
            await #expect(throws: WorkspaceFileImageLoader.LoadError.notAPDF) {
                _ = try await WorkspacePDF.prepare(fileURL: url, name: "report.pdf", byteCount: bytes.count)
            }
        } else {
            let pdf = try await WorkspacePDF.prepare(fileURL: url, name: "report.pdf", byteCount: bytes.count)
            #expect(pdf.pageCount == 2)
            #expect(PDFDocument(url: pdf.url)?.page(at: 1)?.string?.contains("Second page") == true)
        }
    }

    @Test(arguments: [false, true])
    func encryptedPDFRequiresOnlyANonemptyUserPassword(_ requiresPassword: Bool) async throws {
        let bytes = try Self.encryptedPDFBytes(requiresPassword: requiresPassword)
        let reopened = try #require(PDFDocument(data: bytes))
        #expect(reopened.isEncrypted)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-encrypted-\(UUID()).pdf")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        if requiresPassword {
            #expect(reopened.isLocked)
            await #expect(throws: WorkspaceFileImageLoader.LoadError.pdfPasswordRequired) {
                _ = try await WorkspacePDF.prepare(fileURL: url, name: "report.pdf", byteCount: bytes.count)
            }
            #expect(!FileManager.default.fileExists(atPath: url.path))
        } else {
            let pdf = try await WorkspacePDF.prepare(fileURL: url, name: "report.pdf", byteCount: bytes.count)
            #expect(pdf.pageCount == 2)
            let viewerDocument = try WorkspacePDF.openDocument(at: pdf.url)
            #expect(!viewerDocument.isLocked)
            #expect(viewerDocument.page(at: 1)?.string?.contains("Second page") == true)
        }
    }

    private func pdfAttachmentLoader(
        fileLoader: WorkspaceFileImageLoader, workspaceId: String? = "current"
    ) -> IntentFileAttachmentLoader<URLAttachmentLoader<ImageAttachment>> {
        var loader = IntentFileAttachmentLoader(workspaceId: workspaceId, fallback: .image())
        loader.filePDF = { workspaceId, path in
            try await fileLoader.pdf(workspaceId: workspaceId, path: path)
        }
        return loader
    }

    private func pdfForbiddenFallback() -> AnyAttachment {
        Issue.record("Workspace PDF embeds must not reach the network fallback")
        return AnyAttachment(IntentFileFailureAttachment(altText: "unexpected fallback"))
    }

    private static func pdfChunk(_ data: Data, size: Int) -> [String: Any] {
        ["content": data.base64EncodedString(), "bytesRead": data.count, "size": size]
    }

    private static func encryptedPDFBytes(requiresPassword: Bool) throws -> Data {
        let document = try #require(PDFDocument(data: pdfBytes()))
        return try #require(document.dataRepresentation(options: [
            PDFDocumentWriteOption.ownerPasswordOption: "test-owner",
            PDFDocumentWriteOption.userPasswordOption: requiresPassword ? "test-reader" : ""
        ]))
    }

    private static func pdfBytes() -> Data {
        let pageWidth: CGFloat = 300
        let pageHeight: CGFloat = 400
        let textInset: CGFloat = 20
        let bounds = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for title in ["First page", "Second page"] {
                context.beginPage()
                UIColor.white.setFill()
                context.fill(bounds)
                NSAttributedString(string: title, attributes: [.font: UIFont.systemFont(ofSize: textInset)])
                    .draw(at: CGPoint(x: textInset, y: textInset))
            }
        }
    }

    /// Real request-timeout race, with bandwidth and deadline scaled equally to
    /// keep the test fast. At 1 Mbit/s, a 4 MiB base64 response takes >40 s.
    @MainActor
    private final class SlowPDFConnection: FakeConnectionManager {
        let bytes: Data
        private let manager = ConnectionManager(diagnostics: DiagnosticStore(storage: DiagnosticTestStorage()))
        private let timeScale = 0.03
        private let bytesPerSecond: Double = 125_000

        init(bytes: Data) { self.bytes = bytes }

        override func request(
            _ method: String, params: [String: Any] = [:], timeout: TimeInterval = ConnectionManager.defaultRequestTimeout
        ) async throws -> Any {
            requestLog.append(RequestLogEntry(method: method, params: params, timestamp: Date()))
            let offset = try #require(params["offset"] as? Int)
            let length = try #require(params["length"] as? Int)
            let chunk = bytes.subdata(in: offset..<min(offset + length, bytes.count))
            let encodedLength = Double(chunk.base64EncodedString().utf8.count)
            let delay = encodedLength / bytesPerSecond * timeScale
            let id = requestLog.count
            return try await manager.awaitResponse(id: id, timeout: timeout * timeScale) {
                Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    self.manager.handleTextMessage("""
                    {"id":\(id),"result":{"content":"\(chunk.base64EncodedString())","bytesRead":\(chunk.count),"size":\(self.bytes.count)}}
                    """)
                }
            }
        }
    }
}

extension IntentFileAttachmentLoaderTests {
    @Test func pdfRetryDoesNotClearAnotherWorkspaceFailure() async throws {
        let connection = FakeConnectionManager()
        connection.errorMap["file.readChunk"] = URLError(.timedOut)
        let loader = WorkspaceFileImageLoader(connection: connection)
        for workspace in ["current", "linked"] {
            await #expect(throws: URLError.self) { _ = try await loader.pdf(workspaceId: workspace, path: "report.pdf") }
        }
        connection.errorMap["file.readChunk"] = nil
        let bytes = Self.pdfBytes()
        connection.responseMap["file.readChunk"] = Self.pdfChunk(bytes, size: bytes.count)
        loader.forgetFailure(workspaceId: "linked", path: "report.pdf")
        let pdf = try await loader.pdf(workspaceId: "linked", path: "report.pdf")
        #expect(pdf.pageCount == 2)
        await #expect(throws: WorkspaceFileImageLoader.LoadError.previouslyFailed) {
            _ = try await loader.pdf(workspaceId: "current", path: "report.pdf")
        }
        #expect(connection.paramsForMethod("file.readChunk").count == 3)
    }

    @Test(arguments: ["timeout", "remote", "malformed", "oversized", "invalid", "locked", "cancelled"])
    func pdfFailureDiagnosticsAreSpecificPrivateAndNotRepeated(_ scenario: String) async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        let connection = PDFDiagnosticConnection(store: store)
        connection.rejection = scenario
        let marker = "synthetic-private-pdf-name-and-workspace"
        let expected: DiagnosticFailure.Classification
        switch scenario {
        case "timeout": expected = .requestTimeout
        case "remote": expected = .remoteRejected
        case "malformed":
            expected = .malformedResponse
            connection.responseMap["file.readChunk"] = ["content": marker]
        case "oversized":
            expected = .tooLarge
            connection.responseMap["file.readChunk"] = Self.pdfChunk(Data(), size: WorkspacePDF.maxBytes + 1)
        case "locked":
            expected = .passwordRequired
            let bytes = try Self.encryptedPDFBytes(requiresPassword: true)
            connection.responseMap["file.readChunk"] = Self.pdfChunk(bytes, size: bytes.count)
        case "cancelled":
            expected = .none
            connection.errorMap["file.readChunk"] = CancellationError()
        default:
            expected = .unreadable
            connection.responseMap["file.readChunk"] = Self.pdfChunk(Data(marker.utf8), size: marker.utf8.count)
        }
        let loader = WorkspaceFileImageLoader(connection: connection, diagnostics: store)
        for _ in 0..<2 {
            await #expect(throws: (any Error).self) { _ = try await loader.pdf(workspaceId: marker, path: marker + ".pdf") }
        }
        let snapshot = await store.snapshot()
        let records = try DiagnosticFixtures.records(snapshot)
        if scenario == "cancelled" {
            #expect(records.isEmpty)
            return
        }
        let event = try #require(records.first?.event)
        #expect(records.count == 1 && records.first?.count == 1)
        #expect(event.operation == .pdfLoad)
        #expect(event.failure.classification == expected)
        let remoteOrTimeout = scenario == "remote" || scenario == "timeout"
        #expect(event.stage == (remoteOrTimeout ? .request : (scenario == "invalid" || scenario == "locked" ? .decode : .response)))
        #expect(event.failure.origin == (scenario == "remote" ? .remoteRPC : (scenario == "timeout" ? .localRequest : .localOperation)))
        let exported = try #require(String(data: snapshot.jsonLines, encoding: .utf8))
        #expect(!exported.contains(marker))
    }

    @MainActor
    private final class PDFDiagnosticConnection: FakeConnectionManager {
        let manager: ConnectionManager
        var rejection = ""

        init(store: DiagnosticStore) { manager = ConnectionManager(diagnostics: store) }

        override func request(
            _ method: String, params: [String: Any] = [:], timeout: TimeInterval = ConnectionManager.defaultRequestTimeout
        ) async throws -> Any {
            guard rejection == "timeout" || rejection == "remote" else {
                return try await super.request(method, params: params, timeout: timeout)
            }
            return try await manager.awaitResponse(id: 1, timeout: rejection == "timeout" ? 0 : timeout) {
                if self.rejection == "remote" {
                    self.manager.handleTextMessage("""
                    {"id":1,"error":{"code":-32603,"message":"synthetic-private-pdf-name-and-workspace"}}
                    """)
                }
                return nil
            }
        }
    }
}
