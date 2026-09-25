import Foundation
@testable import Intent
import Testing
import Textual
import UIKit

@MainActor
struct WorkspaceAssetMarkdownTests {
    @Test(arguments: [
        "workspace-asset://ws-1/picture.png",
        "WORKSPACE-ASSET://ws-1/picture.png?v=2#preview",
        "workspace-asset://ws-1/picture%2Epng?backend=untrusted"
    ])
    func routesSavedAssetURLs(_ source: String) throws {
        let url = try #require(URL(string: source))
        #expect(MarkdownImageRoute.route(for: url) == .workspaceAsset(
            WorkspaceAssetLink(workspaceId: "ws-1", assetId: "picture.png")
        ))
    }

    @Test func decodesAssetIdentifierOnceWithoutQueryOrFragment() throws {
        let url = try #require(URL(string: "workspace-asset://ws-1/chart%20%23%3F.png?v=3#preview"))
        #expect(WorkspaceAssetLink.parse(url) == WorkspaceAssetLink(
            workspaceId: "ws-1", assetId: "chart #?.png"
        ))
        let doubleEncoded = try #require(URL(string: "workspace-asset://ws-1/chart%252Epng"))
        #expect(WorkspaceAssetLink.parse(doubleEncoded) == WorkspaceAssetLink(
            workspaceId: "ws-1", assetId: "chart%2Epng"
        ))
    }

    @Test(arguments: [
        "workspace-asset:///picture.png", "workspace-asset://ws-1",
        "workspace-asset://ws-1/", "workspace-asset://ws-1//picture.png",
        "workspace-asset://ws-1/picture.png/", "workspace-asset://ws-1/folder/picture.png",
        "workspace-asset://ws-1/..", "workspace-asset://ws-1/%2E",
        "workspace-asset://ws-1/%2e%2e", "workspace-asset://ws-1/../picture.png",
        "workspace-asset://ws-1/folder%2Fpicture.png", "workspace-asset://ws-1/folder%5Cpicture.png",
        "workspace-asset://ws-1/%00.png", "workspace-asset://ws-1/%20", "workspace-asset://ws-1/%FF.png",
        "workspace-asset://user@ws-1/picture.png", "workspace-asset://ws-1:80/picture.png"
    ])
    func malformedLinksFailLocallyWithoutFetching(_ source: String) async throws {
        let url = try #require(URL(string: source))
        #expect(MarkdownImageRoute.route(for: url) == .workspaceAsset(nil))
        var loader = IntentFileAttachmentLoader(workspaceId: "current-workspace", fallback: .image())
        loader.assetMedia = { _, _ in
            Issue.record("Malformed saved-asset URLs must not fetch")
            return .image(UIImage())
        }
        loader.fileImage = { _, _ in
            Issue.record("Saved assets must not use file reads")
            return UIImage()
        }
        loader.remoteImage = { _ in
            Issue.record("Saved assets must not use HTTP")
            return UIImage()
        }

        let attachment = try await loader.resolvedAttachment(for: url, text: "bad image", fallback: forbiddenFallback)

        #expect((attachment.base as? IntentFileFailureAttachment)?.altText == "bad image")
        #expect(MarkdownTextView.lightboxImage(for: attachment) == nil)
    }

    @Test func savedAssetUsesURLWorkspaceAndExistingLightboxWithoutCurrentWorkspace() async throws {
        let connection = FakeConnectionManager()
        connection.responseMap["note.readAsset"] = Self.imageResponse()
        let imageLoader = WorkspaceFileImageLoader(connection: connection)
        var loader = IntentFileAttachmentLoader(workspaceId: nil, fallback: .image())
        loader.assetMedia = { workspaceId, assetId in
            try await imageLoader.assetMedia(workspaceId: workspaceId, assetId: assetId)
        }
        let url = try #require(URL(string: "workspace-asset://linked-workspace/chart%20one.png?v=2&backend=other"))

        let attachment = try await loader.resolvedAttachment(for: url, text: "Saved chart", fallback: forbiddenFallback)

        let loaded = try #require(attachment.base as? IntentFileImageAttachment)
        #expect(loaded.altText == "Saved chart")
        #expect(loaded.image.size.width > 0)
        #expect(MarkdownTextView.lightboxImage(for: attachment) === loaded.image)
        let params = try #require(connection.paramsForMethod("note.readAsset").first)
        #expect(params["workspaceId"] as? String == "linked-workspace")
        #expect(params["asset"] as? String == "chart one.png")
        #expect(params.count == 2)
        #expect(connection.paramsForMethod("file.readChunk").isEmpty)
    }

    @Test(arguments: ["missing", "invalid-base64", "non-image", "malformed", "cancelled"])
    func assetFailuresYieldInertPlaceholder(_ failure: String) async throws {
        let connection = FakeConnectionManager()
        switch failure {
        case "missing": connection.errorMap["note.readAsset"] = NSError(domain: "missing-asset", code: 404)
        case "cancelled": connection.errorMap["note.readAsset"] = CancellationError()
        case "invalid-base64": connection.responseMap["note.readAsset"] = ["data": "%%invalid%%"]
        case "non-image":
            connection.responseMap["note.readAsset"] = [
                "data": Data("plain text".utf8).base64EncodedString(), "mimeType": "text/plain"
            ]
        default: connection.responseMap["note.readAsset"] = ["assetId": "image.png"]
        }
        let imageLoader = WorkspaceFileImageLoader(connection: connection)
        var loader = IntentFileAttachmentLoader(workspaceId: "ws-1", fallback: .image())
        loader.assetMedia = { workspaceId, assetId in
            try await imageLoader.assetMedia(workspaceId: workspaceId, assetId: assetId)
        }
        let url = try #require(URL(string: "workspace-asset://ws-1/image.png"))

        let attachment = try await loader.resolvedAttachment(for: url, text: "Unavailable chart", fallback: forbiddenFallback)

        #expect((attachment.base as? IntentFileFailureAttachment)?.altText == "Unavailable chart")
        #expect(MarkdownTextView.lightboxImage(for: attachment) == nil)
        #expect(connection.paramsForMethod("note.readAsset").count == 1)
    }

    @Test func markdownAssetFetcherStaysBoundToEachSessionDespiteBackendHints() async throws {
        let firstConnection = FakeConnectionManager()
        let secondConnection = FakeConnectionManager()
        firstConnection.responseMap["note.readAsset"] = Self.imageResponse()
        secondConnection.errorMap["note.readAsset"] = NSError(domain: "other-backend", code: 404)
        let firstSession = Self.makeSession(connection: firstConnection)
        let secondSession = Self.makeSession(connection: secondConnection)
        let url = try #require(URL(string: "workspace-asset://linked-workspace/image.png?backend=other&v=2"))
        var loader = IntentFileAttachmentLoader(workspaceId: "current-workspace", fallback: .image())
        loader.assetMedia = MarkdownTextView.assetMediaFetcher(session: firstSession)

        let first = try await loader.resolvedAttachment(for: url, text: "first", fallback: forbiddenFallback)
        #expect(first.base is IntentFileImageAttachment)
        #expect(secondConnection.paramsForMethod("note.readAsset").isEmpty)

        loader.assetMedia = MarkdownTextView.assetMediaFetcher(session: secondSession)
        let second = try await loader.resolvedAttachment(for: url, text: "second", fallback: forbiddenFallback)
        #expect(second.base is IntentFileFailureAttachment)
        #expect(firstConnection.paramsForMethod("note.readAsset").count == 1)
        #expect(secondConnection.paramsForMethod("note.readAsset").count == 1)

        loader.assetMedia = MarkdownTextView.assetMediaFetcher(session: firstSession)
        let cached = try await loader.resolvedAttachment(for: url, text: "cached", fallback: forbiddenFallback)
        #expect(MarkdownTextView.lightboxImage(for: cached) === MarkdownTextView.lightboxImage(for: first))
        #expect(firstConnection.paramsForMethod("note.readAsset").count == 1)
        let params = try #require(firstConnection.paramsForMethod("note.readAsset").first)
        #expect(params["workspaceId"] as? String == "linked-workspace")
        #expect(params["asset"] as? String == "image.png")
    }

    private static func makeSession(connection: FakeConnectionManager) -> BackendSession {
        let store = WorkspaceStore(forTesting: true)
        let fileLoader = WorkspaceFileImageLoader(connection: connection)
        return BackendSession(
            backendID: BackendID(UUID()),
            connection: connection,
            workspaceStore: store,
            coordinatorFactory: { claim in
                AppCoordinator(workspaceStore: store, connection: connection, claimScreenRestoration: claim)
            },
            githubRepoStore: GitHubRepoStore(connectionManager: connection),
            creationOptionsStore: CreationOptionsStore(connectionManager: connection),
            prMonitorsStore: WorkspacePrMonitorsStore(connectionManager: connection),
            attachmentUploadService: AttachmentUploadService(connection: connection),
            workspaceFileImageLoader: fileLoader,
            attachmentImageLoader: AttachmentImageLoader(connection: connection, fileLoader: fileLoader),
            attentionCueCenter: WorkspaceAttentionCueCenter {}
        )
    }

    private func forbiddenFallback() async -> AnyAttachment {
        Issue.record("Saved assets must never reach the network fallback")
        return AnyAttachment(IntentFileFailureAttachment(altText: "unexpected fallback"))
    }

    private static func imageResponse() -> [String: Any] {
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return ["data": bytes.base64EncodedString(), "mimeType": "image/png"]
    }
}
