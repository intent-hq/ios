import SwiftUI

nonisolated enum WorkspaceStatusImageLayout {
    static let accessibilityIdentifier = "workspaceDetail.statusImage"
    static let accessibilityLabel = "Workspace status image"

    static func normalizedAssetId(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func assetId(for workspace: Workspace?) -> String? {
        normalizedAssetId(workspace?.statusImageAssetId)
    }

    static func loadKey(workspaceId: String, assetId: String, attempt: Int) -> String {
        "\(workspaceId)|\(assetId)|\(attempt)"
    }
}

struct WorkspaceStatusImageView: View {
    typealias Layout = WorkspaceStatusImageLayout

    let workspaceId: String
    let assetId: String
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
                    guard !Task.isCancelled else { return }
                    image = loaded
                    loadedKey = key
                } catch is CancellationError {
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
                    .scaledToFill()
                    .frame(width: Layout.thumbnailSize, height: Layout.thumbnailSize, alignment: .top)
                    .clipShape(thumbnailShape)
                    .overlay(border)
                    .contentShape(thumbnailShape)
            }
            .buttonStyle(IntentContentButtonStyle())
            .accessibilityLabel(Layout.accessibilityLabel)
            .accessibilityHint("Opens the image full size")
            .accessibilityIdentifier(Layout.accessibilityIdentifier)
            .contextMenu {
                ImageActionMenuItems(image: image)
            }
            .imageSaveAlert()
            .fullScreenCover(isPresented: $lightboxPresented) {
                ImageLightboxView(image: image)
            }
        } else if failed {
            Button { attempt += 1 } label: {
                placeholder { Image(systemName: "photo.badge.exclamationmark") }
            }
            .buttonStyle(IntentContentButtonStyle())
            .accessibilityLabel("Status image unavailable")
            .accessibilityHint("Retries loading the image")
        } else {
            placeholder { ProgressView().controlSize(.mini) }
                .accessibilityHidden(true)
        }
    }

    private var thumbnailShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Layout.cornerRadius)
    }

    private var border: some View {
        thumbnailShape.strokeBorder(Theme.border(for: colorScheme), lineWidth: Layout.borderWidth)
    }

    private func placeholder(@ViewBuilder _ icon: () -> some View) -> some View {
        icon()
            .font(.caption)
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .frame(width: Layout.thumbnailSize, height: Layout.thumbnailSize)
            .background(Theme.muted(for: colorScheme).opacity(Layout.placeholderOpacity))
            .clipShape(thumbnailShape)
    }
}
