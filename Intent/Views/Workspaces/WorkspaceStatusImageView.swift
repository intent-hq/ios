import SwiftUI

/// Pure mapping for the workspace status image (PROTOCOL §5.1
/// `statusImageAssetId`; FE parity: WorkspaceProgressCard.svelte): which
/// workspaces render one in their detail header and how the fetch is keyed.
nonisolated enum WorkspaceStatusImageLayout {
    static let accessibilityIdentifier = "workspaceDetail.statusImage"
    static let accessibilityLabel = "Workspace status image"

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
}

/// Renders a workspace's status screenshot, fetched through the session's
/// `WorkspaceFileImageLoader` asset path (`note.readAsset`). Callers only
/// mount it when `WorkspaceStatusImageLayout.assetId(for:)` is non-nil, so
/// an unset image leaves no gap.
struct WorkspaceStatusImageView: View {
    typealias Layout = WorkspaceStatusImageLayout

    let workspaceId: String
    let assetId: String
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
                    // View disappeared / workspace changed mid-fetch.
                } catch {
                    if !Task.isCancelled { failed = true }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Button { lightboxPresented = true } label: {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel(Layout.accessibilityLabel)
                    .frame(maxHeight: Layout.detailMaxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
                    .overlay(border)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(IntentContentButtonStyle())
            .accessibilityLabel(Layout.accessibilityLabel)
            .accessibilityHint("Opens the image full size")
            .accessibilityIdentifier(Layout.accessibilityIdentifier)
            .contextMenu {
                ImageActionMenuItems(image: image)
            }
            .fullScreenCover(isPresented: $lightboxPresented) {
                ImageLightboxView(image: image)
            }
        } else if failed {
            Button { attempt += 1 } label: {
                placeholder(
                    systemImage: "photo.badge.exclamationmark",
                    text: "Status image unavailable — tap to retry"
                )
            }
            .buttonStyle(IntentContentButtonStyle())
            .accessibilityLabel("Status image unavailable")
            .accessibilityHint("Retries loading the image")
        } else {
            placeholder(systemImage: nil, text: "Loading status image…")
                .accessibilityHidden(true)
        }
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
                .interFont(Constants.Typography.subtextXXS)
        }
        .font(.caption)
        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        .frame(maxWidth: .infinity)
        .frame(height: Layout.detailPlaceholderHeight)
        .background(Theme.muted(for: colorScheme).opacity(Layout.placeholderOpacity))
        .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
    }
}
