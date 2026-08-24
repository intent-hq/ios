import MarkdownUI
import SwiftUI

/// MarkdownUI block-image provider that renders `![alt](intent://local/[ws-id/]file/<path>)`
/// images by fetching the file's bytes from the daemon; every other URL falls
/// through to MarkdownUI's default (network) provider.
struct IntentFileImageProvider: ImageProvider {
    /// Workspace resolving short-form links (no workspace segment in the URL).
    let workspaceId: String?

    @ViewBuilder
    func makeImage(url: URL?) -> some View {
        if let url, let link = IntentFileLink.parse(url) {
            IntentFileImageView(link: link, defaultWorkspaceId: workspaceId)
        } else {
            DefaultImageProvider.default.makeImage(url: url)
        }
    }
}

/// Inline (within-text) counterpart: MarkdownUI routes images that share a
/// paragraph with text through `InlineImageProvider` instead.
struct IntentFileInlineImageProvider: InlineImageProvider {
    let workspaceId: String?

    func image(with url: URL, label: String) async throws -> Image {
        guard let link = IntentFileLink.parse(url) else {
            return try await DefaultInlineImageProvider.default.image(with: url, label: label)
        }
        guard link.isImage, let ws = link.workspaceId ?? workspaceId else {
            throw WorkspaceFileImageLoader.LoadError.notAnImage
        }
        let uiImage = try await WorkspaceFileImageLoader.shared.image(workspaceId: ws, path: link.path)
        return Image(uiImage: uiImage)
    }
}

/// Async-loading view for one intent-file image: placeholder while fetching,
/// the image (tap for lightbox) on success, and a graceful placeholder on any
/// failure — non-image extensions, missing workspace, fetch/decode errors.
struct IntentFileImageView: View {
    let link: IntentFileLink
    let defaultWorkspaceId: String?

    private enum Phase {
        case loading
        case loaded(UIImage)
        case failed
    }

    @State private var phase: Phase = .loading
    @State private var lightboxPresented = false
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        content
            .task(id: taskKey) { await load() }
    }

    /// Re-fetch when the link (or resolved workspace) changes under view reuse.
    private var taskKey: String {
        "\(resolvedWorkspaceId ?? "")\u{0}\(link.path)"
    }

    private var resolvedWorkspaceId: String? {
        link.workspaceId ?? defaultWorkspaceId
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
                .frame(width: 120, height: 80)
                .background(Theme.muted(for: colorScheme).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        case .loaded(let uiImage):
            Button { lightboxPresented = true } label: {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .fullScreenCover(isPresented: $lightboxPresented) {
                ImageLightboxView(image: uiImage)
            }
        case .failed:
            ImageDecodeFailureView()
        }
    }

    @MainActor
    private func load() async {
        guard link.isImage, let ws = resolvedWorkspaceId else {
            phase = .failed
            return
        }
        phase = .loading
        do {
            let image = try await WorkspaceFileImageLoader.shared.image(workspaceId: ws, path: link.path)
            phase = .loaded(image)
        } catch {
            phase = .failed
        }
    }
}
