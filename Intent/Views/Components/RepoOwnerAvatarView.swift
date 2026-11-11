import SwiftUI

/// Circular GitHub repo-owner avatar loaded from the public
/// `https://github.com/{owner}.png` endpoint, with a folder icon fallback
/// while loading and when the owner is unknown or the image fails to load. Mirrors the
/// avatar treatment in the desktop `RepoSelector`.
struct RepoOwnerAvatarView: View {
    let owner: String?
    var size: CGFloat = Constants.RepoOwnerAvatar.defaultSize
    var fallbackSymbol: String?
    var cornerRadius: CGFloat?
    var loader: RemoteImageLoader = .shared

    @Environment(\.colorScheme) private var colorScheme
    @State private var loadedAvatar: LoadedAvatar?

    private struct LoadedAvatar {
        let url: URL
        let image: UIImage
    }

    /// URL for a GitHub owner avatar, or nil when the owner is missing/empty.
    static func avatarURL(for owner: String?) -> URL? {
        guard let owner, !owner.isEmpty else { return nil }
        return URL(string: "https://github.com/\(owner).png?size=\(Constants.RepoOwnerAvatar.requestPixelSize)")
    }

    private var avatarURL: URL? { Self.avatarURL(for: owner) }

    var body: some View {
        Group {
            if let avatarURL, let loadedAvatar, loadedAvatar.url == avatarURL {
                Image(uiImage: loadedAvatar.image)
                    .resizable()
                    .scaledToFill()
            } else {
                fallbackIcon
            }
        }
        .task(id: avatarURL) {
            guard let url = avatarURL else {
                loadedAvatar = nil
                return
            }
            guard loadedAvatar?.url != url else { return }
            if let image = try? await loader.image(for: url), !Task.isCancelled {
                loadedAvatar = LoadedAvatar(url: url, image: image)
            }
        }
        .frame(width: size, height: size)
        .clipShape(avatarShape)
        .overlay(
            avatarShape
                .stroke(
                    Color.white.opacity(Constants.RepoOwnerAvatar.borderOpacity),
                    lineWidth: Constants.RepoOwnerAvatar.borderWidth
                )
        )
        .accessibilityHidden(true)
    }

    private var avatarShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius ?? size / 2, style: .circular)
    }

    private var fallbackIcon: some View {
        Group {
            if let fallbackSymbol {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: size * Constants.RepoOwnerAvatar.fallbackScale))
            } else {
                Image(.folder)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * Constants.RepoOwnerAvatar.fallbackScale, height: size * Constants.RepoOwnerAvatar.fallbackScale)
            }
        }
        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        .accessibilityHidden(true)
    }
}
