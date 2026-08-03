import SwiftUI

/// Circular GitHub repo-owner avatar loaded from the public
/// `https://github.com/{owner}.png` endpoint, with an SF Symbol fallback
/// while loading and when the owner is unknown or the image fails to load. Mirrors the
/// avatar treatment in the desktop `RepoSelector`.
struct RepoOwnerAvatarView: View {
    let owner: String?
    var size: CGFloat = 28
    var fallbackSymbol: String = "folder.fill"

    @Environment(\.colorScheme) private var colorScheme

    /// URL for a GitHub owner avatar, or nil when the owner is missing/empty.
    static func avatarURL(for owner: String?) -> URL? {
        guard let owner, !owner.isEmpty else { return nil }
        return URL(string: "https://github.com/\(owner).png?size=64")
    }

    var body: some View {
        Group {
            if let url = Self.avatarURL(for: owner) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        fallbackIcon
                    }
                }
            } else {
                fallbackIcon
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }

    private var fallbackIcon: some View {
        Image(systemName: fallbackSymbol)
            .font(.system(size: size * 0.5))
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
    }
}
