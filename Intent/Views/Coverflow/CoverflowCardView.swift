import SwiftUI

// MARK: - Deterministic Repo Color System

/// Generates a pair of gradient colors deterministically from an identifier.
/// Uses a stable djb2 hash instead of Swift's .hashValue (which changes per process).
enum RepoColorSystem {
    /// Stable hash that doesn't change across app runs (unlike Swift's .hashValue)
    static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return hash
    }

    /// Returns two colors for a gradient background, derived from a stable hash.
    static func gradientColors(for identifier: String) -> (Color, Color) {
        let hue = Double(stableHash(identifier) % 360) / 360.0
        let color1 = Color(hue: hue, saturation: 0.35, brightness: 0.25)
        let color2 = Color(
            hue: (hue + 0.08).truncatingRemainder(dividingBy: 1.0),
            saturation: 0.4,
            brightness: 0.18
        )
        return (color1, color2)
    }

    /// Light-mode variant with higher brightness.
    static func gradientColorsLight(for identifier: String) -> (Color, Color) {
        let hue = Double(stableHash(identifier) % 360) / 360.0
        let color1 = Color(hue: hue, saturation: 0.15, brightness: 0.95)
        let color2 = Color(
            hue: (hue + 0.08).truncatingRemainder(dividingBy: 1.0),
            saturation: 0.2,
            brightness: 0.90
        )
        return (color1, color2)
    }

    /// Returns the agent's accent color for glow effects.
    static func agentAccentColor(for agentId: String) -> Color {
        let hue = Double(stableHash(agentId) % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.9)
    }
}

// MARK: - CoverflowCardView

struct CoverflowCardView: View {
    let coverflowAgent: CoverflowAgent
    @ObservedObject var conversationViewModel: ConversationViewModel
    var isExposeMode: Bool = false
    var showConversation: Bool = true
    var conversationOpacity: Double = 1.0
    var isHorizontalSwiping: Bool = false
    var isKeyboardVisible: Bool = false
    var onJumpToConversation: (() -> Void)? = nil
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject private var store = CoverflowStore.shared
    private var isStreaming: Bool {
        CoverflowStore.shared.isAgentStreaming(coverflowAgent.id)
    }

    private var gradientColors: (Color, Color) {
        if colorScheme == .dark {
            return RepoColorSystem.gradientColors(for: coverflowAgent.workspaceId)
        } else {
            return RepoColorSystem.gradientColorsLight(for: coverflowAgent.workspaceId)
        }
    }

    /// The chrome/border color derived from repo gradient
    private var chromeColor: Color {
        let (c1, _) = gradientColors
        return c1
    }

    /// Brighter variant for text on chrome
    private var chromeBrightColor: Color {
        let hue = Double(RepoColorSystem.stableHash(coverflowAgent.workspaceId) % 360) / 360.0
        return Color(hue: hue, saturation: 0.5, brightness: 0.85)
    }

    private var accentColor: Color {
        RepoColorSystem.agentAccentColor(for: coverflowAgent.id)
    }

    var body: some View {
        // Outer ZStack: avatar layer sits ABOVE the clipped card body
        ZStack(alignment: .topLeading) {
            // The clipped card body (chrome + content + border)
            cardBody

            // Overshooting avatar — NOT clipped, visually bleeds outside
            if !isKeyboardVisible {
                overshootingAvatar
                    .offset(x: isExposeMode ? -20 : -45, y: isExposeMode ? -12 : -30)
            }
        }
        .shadow(
            color: isStreaming
                ? accentColor.opacity(0.3)
                : Color.black.opacity(colorScheme == .dark ? 0.5 : 0.15),
            radius: isStreaming ? 20 : 12,
            y: 4
        )

    }

    // MARK: - Card Body (clipped)

    @ViewBuilder
    private var cardBody: some View {
        ZStack(alignment: .topLeading) {
            // Card chrome/border background
            cardChrome

            // Content layout
            VStack(spacing: 0) {
                if !isKeyboardVisible {
                    // Colored title bar with repo + agent name
                    titleBar
                        .padding(.leading, isExposeMode ? 32 : 68) // space for overshooting avatar
                        .padding(.trailing, isExposeMode ? 8 : 16)
                        .padding(.vertical, isExposeMode ? 6 : 12)
                }

                // Recessed conversation well
                conversationWell
                    .padding(.horizontal, 10)
            }

            // Jump button — top right, only in coverflow mode
            if !isExposeMode && !isKeyboardVisible {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            onJumpToConversation?()
                        } label: {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.gray.opacity(0.4))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .padding(.trailing, 16)
                    }
                    .padding(.vertical, 12)
                    Spacer()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            // Colored border
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [chromeBrightColor.opacity(0.7), chromeColor.opacity(0.5)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 3
                )
        )

    }

    // MARK: - Card Chrome (colored background)

    @ViewBuilder
    private var cardChrome: some View {
        let (c1, c2) = gradientColors
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [c1, c2],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    // MARK: - Title Bar

    @ViewBuilder
    private var titleBar: some View {
        HStack(alignment: .center, spacing: 10) {
            // GitHub repo owner avatar
            if let owner = coverflowAgent.repositoryOwner, !owner.isEmpty {
                AsyncImage(url: URL(string: "https://github.com/\(owner).png?size=64")) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        Image(systemName: "building.2.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.5) : Color(white: 0.4))
                    default:
                        Color.clear
                    }
                }
                .frame(width: isExposeMode ? 20 : 34, height: isExposeMode ? 20 : 34)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
            }

            VStack(alignment: .leading, spacing: 2) {
                // Workspace · Repo · idle/streaming breadcrumb
                HStack(spacing: 0) {
                    if !coverflowAgent.name.isEmpty {
                        Text(coverflowAgent.name)
                            .font(isExposeMode ? .caption2 : .caption)
                            .fontWeight(.medium)
                            .foregroundStyle(colorScheme == .dark ? .white : Color(white: 0.1))
                            .lineLimit(1)
                        Text(" · ")
                            .font(isExposeMode ? .caption2 : .caption)
                            .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.6) : Color(white: 0.3))
                    }
                    Text(coverflowAgent.repositoryName)
                        .font(isExposeMode ? .caption2 : .caption)
                        .fontWeight(.medium)
                        .foregroundStyle(colorScheme == .dark ? .white : Color(white: 0.1))
                        .lineLimit(1)
                    // Idle duration or streaming indicator
                    Text(" · ")
                        .font(isExposeMode ? .caption2 : .caption)
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.6) : Color(white: 0.3))
                    if isStreaming {
                        Text("Thinking")
                            .font(isExposeMode ? .caption2 : .caption)
                            .fontWeight(.bold)
                            .foregroundStyle(.green)
                            .lineLimit(1)
                    } else if let idle = coverflowAgent.idleString {
                        Text(idle)
                            .font(isExposeMode ? .caption2 : .caption)
                            .fontWeight(.bold)
                            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                            .lineLimit(1)
                    }
                }

                // Workspace title
                Text(coverflowAgent.workspaceTitle)
                    .font(isExposeMode ? .caption : .subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(colorScheme == .dark ? Color.white : Color(white: 0.1))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Overshooting Avatar

    @ViewBuilder
    private var overshootingAvatar: some View {
        AuggieAvatarView(
            seed: coverflowAgent.id,
            size: isExposeMode ? 50 : 110,
            specialist: coverflowAgent.specialist,
            isActive: isStreaming
        )
    }

    // MARK: - Conversation Well (recessed inset)

    @ViewBuilder
    private var conversationWell: some View {
        Group {
            if showConversation {
                GeometryReader { geo in
                    ConversationView(viewModel: conversationViewModel, isExposeMode: isExposeMode)
                        .frame(
                            width: isExposeMode ? geo.size.width / 0.6 : geo.size.width,
                            height: isExposeMode ? geo.size.height / 0.6 : geo.size.height
                        )
                        .scaleEffect(isExposeMode ? 0.6 : 1.0, anchor: .topLeading)
                        .allowsHitTesting(!isExposeMode && !isHorizontalSwiping)
                }
                .clipped()
                .opacity(conversationOpacity)
            } else {
                // Lightweight placeholder — just the background shape
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        colorScheme == .dark
                            ? Color(white: 0.04)
                            : Color(white: 0.94)
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? Color(white: 0.04)
                        : Color(white: 0.94)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    colorScheme == .dark
                        ? Color.white.opacity(0.06)
                        : Color.black.opacity(0.08),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.bottom, 10) // bottom chrome spacing
    }
}
