import SwiftUI

/// Pure mapping for the workspace status image (PROTOCOL §5.1
/// `statusImageAssetId`; FE parity: WorkspaceProgressCard.svelte): which
/// workspaces render one, how the fetch is keyed, and how each placement
/// degrades when the asset cannot be loaded.
nonisolated enum WorkspaceStatusImageLayout {
    enum Style: Equatable {
        /// Workspace list row: small square thumbnail trailing the text.
        case card
        /// Workspace detail header: full-width banner that opens the lightbox.
        case detail
    }

    /// The daemon omits the field until set and folds blanks to a clear;
    /// mirror that so an empty id never reaches the loader.
    static func normalizedAssetId(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func assetId(for workspace: Workspace?) -> String? {
        normalizedAssetId(workspace?.statusImageAssetId)
    }

    /// `.task(id:)` key: a replaced asset (new content-addressed id) or a
    /// retry tap re-runs the fetch; a removal unmounts the view entirely.
    static func loadKey(workspaceId: String, assetId: String, attempt: Int) -> String {
        "\(workspaceId)|\(assetId)|\(attempt)"
    }

    /// The row has no room for an error affordance, so a broken asset
    /// collapses to the plain row (desktop parity); the detail header keeps
    /// a non-broken placeholder with a retry.
    static func hidesOnFailure(_ style: Style) -> Bool {
        style == .card
    }

    static func accessibilityIdentifier(for style: Style) -> String {
        switch style {
        case .card: "workspaceRow.statusImage"
        case .detail: "workspaceDetail.statusImage"
        }
    }

    static func accessibilityLabel(for _: Style) -> String {
        "Workspace status image"
    }
}

/// Renders a workspace's status screenshot, fetched through the session's
/// `WorkspaceFileImageLoader` asset path (`note.readAsset`). Callers only
/// mount it when `WorkspaceStatusImageLayout.assetId(for:)` is non-nil, so
/// an unset image leaves no gap.
struct WorkspaceStatusImageView: View {
    typealias Layout = WorkspaceStatusImageLayout

    let workspaceId: String
    let assetId: String
    let style: Layout.Style
    /// Explicit loader override (tests/previews); when nil, the window
    /// session's loader is used, falling back to the shared loader.
    var loader: WorkspaceFileImageLoader?
    @Environment(BackendSession.self) private var session: BackendSession?
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?
    @State private var failed = false
    @State private var attempt = 0
    @State private var loadedKey: String?
    @State private var lightboxPresented = false

    var body: some View {
        content
            .task(id: Layout.loadKey(workspaceId: workspaceId, assetId: assetId, attempt: attempt)) {
                let key = Layout.loadKey(workspaceId: workspaceId, assetId: assetId, attempt: 0)
                if loadedKey != key { image = nil }
                guard image == nil else { return }
                failed = false
                let loader = loader ?? session?.workspaceFileImageLoader ?? .shared
                if attempt > 0 {
                    loader.forgetAssetFailure(workspaceId: workspaceId, assetId: assetId)
                }
                do {
                    let loaded = try await loader.assetImage(workspaceId: workspaceId, assetId: assetId)
                    // A replaced asset re-keys the task; never let the
                    // superseded fetch overwrite the newer image.
                    guard !Task.isCancelled else { return }
                    image = loaded
                    loadedKey = key
                } catch is CancellationError {
                    // Row scrolled away / workspace changed mid-fetch.
                } catch {
                    if !Task.isCancelled { failed = true }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            switch style {
            case .card:
                thumbnail(image)
                    .accessibilityLabel(Layout.accessibilityLabel(for: style))
                    .accessibilityIdentifier(Layout.accessibilityIdentifier(for: style))
            case .detail:
                Button { lightboxPresented = true } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel(Layout.accessibilityLabel(for: style))
                        .frame(maxHeight: Layout.detailMaxHeight)
                        .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
                        .overlay(border)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Layout.accessibilityLabel(for: style))
                .accessibilityHint("Opens the image full size")
                .accessibilityIdentifier(Layout.accessibilityIdentifier(for: style))
                .contextMenu {
                    ImageActionMenuItems(image: image)
                }
                .fullScreenCover(isPresented: $lightboxPresented) {
                    ImageLightboxView(image: image)
                }
            }
        } else if failed {
            if Layout.hidesOnFailure(style) {
                // A real (zero-sized) view, not EmptyView, so `.task(id:)`
                // still re-runs when the asset id changes after a failure.
                Color.clear.frame(width: 0, height: 0)
            } else {
                Button { attempt += 1 } label: {
                    placeholder(
                        systemImage: "photo.badge.exclamationmark",
                        text: "Status image unavailable — tap to retry"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Status image unavailable")
                .accessibilityHint("Retries loading the image")
            }
        } else {
            switch style {
            case .card:
                // Reserve the thumbnail's square so the row doesn't shift
                // when the (cached, usually instant) image lands.
                Color.clear
                    .frame(width: Layout.cardThumbnailSide, height: Layout.cardThumbnailSide)
            case .detail:
                placeholder(systemImage: nil, text: "Loading status image…")
                    .accessibilityHidden(true)
            }
        }
    }

    private func thumbnail(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .accessibilityLabel(Layout.accessibilityLabel(for: style))
            .frame(width: Layout.cardThumbnailSide, height: Layout.cardThumbnailSide)
            .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
            .overlay(border)
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: Layout.cornerRadius)
            .strokeBorder(Theme.border(for: colorScheme), lineWidth: Layout.borderWidth)
    }

    /// Fixed-height, full-width band standing in for the detail banner so
    /// the header neither jumps on load nor looks broken on failure.
    private func placeholder(systemImage: String?, text: LocalizedStringKey) -> some View {
        HStack(spacing: Layout.placeholderSpacing) {
            if let systemImage {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            } else {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        .frame(maxWidth: .infinity)
        .frame(height: Layout.detailPlaceholderHeight)
        .background(Theme.muted(for: colorScheme).opacity(Layout.placeholderOpacity))
        .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
    }
}
