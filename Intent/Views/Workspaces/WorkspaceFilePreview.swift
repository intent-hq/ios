import SwiftUI

struct WorkspaceFilePreview: View {
    @ScaledMetric(relativeTo: .title) private var emptyStateIconSize: CGFloat = 48
    let link: TextLinkPreviewView.Link
    @State private var loader: WorkspaceFileImageLoader
    @State private var image: UIImage?
    @State private var video: WorkspaceVideo?
    @State private var hasFailed = false
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
                    if hasFailed {
                        ContentUnavailableView {
                            Label { Text("File unavailable") } icon: {
                                Image(.file).resizable().scaledToFit().frame(width: emptyStateIconSize, height: emptyStateIconSize)
                            }
                        } description: {
                            Text("Could not preview this file. Check your connection and try again.")
                        } actions: {
                            Button("Retry") {
                                loader.forgetFailure(workspaceId: link.workspaceId, path: link.path)
                                attempt += 1
                            }
                            .buttonStyle(IntentContentButtonStyle())
                        }
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
        }
    }

    private func loadMedia() async {
        hasFailed = false
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
            hasFailed = true
        }
    }
}
