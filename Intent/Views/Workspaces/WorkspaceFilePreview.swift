import SwiftUI

struct WorkspaceFilePreview: View {
    @ScaledMetric(relativeTo: .title) private var emptyStateIconSize: CGFloat = 48
    let link: TextLinkPreviewView.Link
    @State private var loader: WorkspaceFileImageLoader
    @State private var image: UIImage?
    @State private var video: WorkspaceVideo?
    @State private var failure: Failure?
    @State private var attempt = 0
    @Environment(\.dismiss) private var dismiss

    init(link: TextLinkPreviewView.Link, connection: any ConnectionManagerRouting) {
        self.link = link
        _loader = State(initialValue: WorkspaceFileImageLoader(connection: connection))
    }

    private var isImage: Bool {
        IntentFileLink(workspaceId: link.workspaceId, path: link.path).isImage
    }

    var body: some View {
        Group {
            if WorkspacePDF.isPDF(path: link.path) {
                PDFLinkPreviewView(link: .init(workspaceId: link.workspaceId, path: link.path), loaderOverride: loader)
            } else if ["html", "htm"].contains(URL(fileURLWithPath: link.path).pathExtension.lowercased()) {
                HTMLLinkPreviewView(link: link, loaderOverride: loader)
            } else if isImage || WorkspaceVideo.isVideo(path: link.path) {
                mediaPreview
            } else {
                TextLinkPreviewView(link: link, loaderOverride: loader)
            }
        }
    }

    @ViewBuilder
    private var mediaPreview: some View {
        if let image {
            ImageLightboxView(image: image)
        } else if let video {
            VideoLightboxView(video: video)
        } else {
            NavigationStack {
                Group {
                    if let failure {
                        failureView(failure)
                    } else {
                        ProgressView("Loading file…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .navigationTitle(link.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        IntentIconButton(icon: .close, label: "Close file") { dismiss() }
                    }
                    .intentToolbarSurface()
                }
            }
            .task(id: attempt) { await loadMedia() }
            .onReconnect {
                guard let failure, failure.canRetry else { return }
                loader.forgetFailure(workspaceId: link.workspaceId, path: link.path)
                attempt += 1
            }
        }
    }

    private func failureView(_ failure: Failure) -> some View {
        ContentUnavailableView {
            Label { Text(failure.title) } icon: {
                Image(.file).resizable().scaledToFit().frame(width: emptyStateIconSize, height: emptyStateIconSize)
            }
        } description: {
            Text(failure.message)
        } actions: {
            if failure.canRetry {
                Button("Retry") {
                    loader.forgetFailure(workspaceId: link.workspaceId, path: link.path)
                    attempt += 1
                }
                .buttonStyle(IntentContentButtonStyle())
                .disabledWhileReadOnly()
            }
        }
        .accessibilityIdentifier("workspaceFilePreview.failure")
    }

    private func loadMedia() async {
        failure = nil
        do {
            if isImage {
                let loaded = try await loader.image(workspaceId: link.workspaceId, path: link.path)
                try Task.checkCancellation()
                image = loaded
            } else {
                let loaded = try await loader.video(workspaceId: link.workspaceId, path: link.path)
                try Task.checkCancellation()
                video = loaded
            }
        } catch {
            guard !Task.isCancelled else { return }
            failure = Failure(error, isImage: isImage, path: link.path)
        }
    }
}

extension WorkspaceFilePreview {
    /// Why a media preview failed, so the message names the real cause
    /// instead of always blaming the connection.
    enum Failure: Equatable {
        /// Over the loader's size cap (in bytes); retrying cannot help.
        case tooLarge(limit: Int)
        /// A type this device cannot show at all (WebM video).
        case unsupported
        /// A supported type whose bytes did not decode; refetching returns
        /// the same bytes, so retrying cannot help.
        case damaged
        /// The reply arrived but was not the shape the app expects.
        case unexpectedResponse
        /// The request itself failed (timeout, disconnect, server error).
        case unavailable

        init(_ error: any Error, isImage: Bool, path: String) {
            switch error as? WorkspaceFileImageLoader.LoadError {
            case .fileTooLarge:
                self = .tooLarge(limit: isImage ? WorkspaceFileImageLoader.maxFileBytes : ImportedPhotoVideo.maxBytes)
            case .notAVideo where WorkspaceVideo.isWebM(path: path):
                self = .unsupported
            case .notAnImage, .notAVideo:
                // Every extension routed to the media preview is one this
                // device decodes, so a decode failure means bad bytes.
                self = .damaged
            case .malformedResponse:
                self = .unexpectedResponse
            default:
                self = .unavailable
            }
        }

        var title: String {
            switch self {
            case .tooLarge: "File too large"
            case .unsupported: "Preview not supported"
            case .damaged: "Can't display file"
            case .unexpectedResponse, .unavailable: "File unavailable"
            }
        }

        var message: String {
            switch self {
            case .tooLarge(let limit):
                let size = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .memory)
                return "This file is too large to preview on this device (over \(size)). Open it on the computer running Intent."
            case .unsupported:
                return "This file type cannot be previewed on this device."
            case .damaged:
                return "This file couldn't be displayed. It may be damaged."
            case .unexpectedResponse:
                return "The file couldn't be loaded. The server sent an unexpected response."
            case .unavailable:
                return "Could not preview this file. Check your connection and try again."
            }
        }

        var canRetry: Bool {
            switch self {
            case .tooLarge, .unsupported, .damaged: false
            case .unexpectedResponse, .unavailable: true
            }
        }
    }
}
