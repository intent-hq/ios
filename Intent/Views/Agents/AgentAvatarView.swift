import SwiftUI

/// Rounded-tile agent avatar with brand artwork and state-aware surfaces.
/// Workspace rows use the iOS assets; other surfaces retain the desktop geometry.
struct AgentAvatarView: View {
    let agentId: String
    var size: CGFloat = Constants.AgentAvatar.defaultSize
    var specialist: String?
    var icon: String?  // Specialist icon metadata (PROTOCOL §5.11)
    var isActive: Bool = false
    var state: AgentAvatarState = .idle
    var workspaceStyle = false
    @Environment(\.colorScheme) private var colorScheme

    private var design: AgentAvatarDesign {
        AgentAvatarDesign.design(agentId: agentId, specialist: specialist, icon: icon)
    }

    // Desktop geometry ratios (avatar-size.ts "standard": surface 20,
    // art 16, clear space 2, corner radius 6).
    private var artSize: CGFloat {
        size * (workspaceStyle ? WorkspaceDetailStyle.avatarArtRatio : Constants.AgentAvatar.artSizeRatio)
    }
    private var cornerRadius: CGFloat {
        size * (workspaceStyle ? WorkspaceDetailStyle.avatarCornerRatio : Constants.AgentAvatar.cornerRadiusRatio)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(surfaceColor)

            artwork

            // Animate only the layer's stroke color in the render server, not
            // SwiftUI geometry: an implicit repeatForever previously made rings
            // drift between rows when a list reordered.
            if isActive {
                AgentAvatarPulse(cornerRadius: cornerRadius)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size, height: size)
        .geometryGroup()
    }

    @ViewBuilder
    private var artwork: some View {
        if workspaceStyle, let resource = design.imageResource {
            Image(resource)
                .resizable()
                .scaledToFit()
                .foregroundStyle(glyphColor)
                .frame(width: artSize, height: artSize)
                .accessibilityHidden(true)
        } else {
            AgentAvatarStrokeShape(glyphPath: design.glyph.strokePath)
                .stroke(glyphColor, style: StrokeStyle(
                    lineWidth: Constants.AgentAvatar.referenceStrokeWidth * artSize
                        / Constants.AgentAvatar.referenceArtSize,
                    lineCap: workspaceStyle ? .butt : .round,
                    lineJoin: workspaceStyle ? .miter : .round
                ))
                .frame(width: artSize, height: artSize)
            AgentAvatarFillShape(glyphPath: design.glyph.fillPath)
                .fill(glyphColor)
                .frame(width: artSize, height: artSize)
        }
    }

    /// Desktop tile surface per state (`--agent-avatar-surface-*` tokens);
    /// idle is the neutral hsl(145 14% 92%) light / hsl(145 12% 78%) dark.
    private var surfaceColor: Color {
        if workspaceStyle, state == .idle || state == .running {
            return design == .coordinator
                ? WorkspaceDetailStyle.accent : WorkspaceDetailStyle.avatarSurface(for: colorScheme)
        }
        switch state {
        case .idle: return Constants.Colors.AgentAvatar.surface
        case .running: return Constants.Colors.AgentAvatar.surfaceActive
        case .waiting: return Constants.Colors.AgentAvatar.surfaceWaiting
        case .failed: return Constants.Colors.AgentAvatar.surfaceFailed
        case .completed: return Constants.Colors.AgentAvatar.surfaceCompleted
        case .question, .attentionDiscussion, .attentionBlocker:
            return Constants.Colors.AgentAvatar.surfaceAttention
        }
    }

    /// Desktop glyph color: near-black (#080808) in both schemes — the tile
    /// stays light, so the glyph stays dark. The completed tile darkens in
    /// dark mode, so it carries its own foreground token.
    private var glyphColor: Color {
        if workspaceStyle, state == .idle || state == .running {
            return design == .coordinator
                ? WorkspaceDetailStyle.onAccent : WorkspaceDetailStyle.avatarForeground(for: colorScheme)
        }
        return state == .completed
            ? Constants.Colors.AgentAvatar.glyphCompleted
            : Constants.Colors.AgentAvatar.glyph
    }
}

struct AgentGroupAvatarStack: View {
    let agents: [AgentSession]
    var totalCount: Int?
    @Environment(\.colorScheme) private var colorScheme

    private let size = WorkspaceDetailStyle.stackAvatarSize

    private var visibleCount: Int {
        min(Constants.AgentRow.maximumHeaderAvatars, max(agents.count, totalCount ?? 0))
    }

    var body: some View {
        HStack(spacing: Constants.AgentRow.avatarOverlap) {
            ForEach(0..<visibleCount, id: \.self) { index in
                avatar(at: index)
                    .clipShape(RoundedRectangle(
                        cornerRadius: size * WorkspaceDetailStyle.avatarCornerRatio, style: .continuous
                    ))
                    .overlay {
                        RoundedRectangle(cornerRadius: size * WorkspaceDetailStyle.avatarCornerRatio, style: .continuous)
                            .strokeBorder(
                                WorkspaceDetailStyle.background(for: colorScheme),
                                lineWidth: WorkspaceDetailStyle.stackBorderWidth
                            )
                    }
                    .zIndex(Double(Constants.AgentRow.maximumHeaderAvatars - index))
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func avatar(at index: Int) -> some View {
        if index < agents.count {
            let agent = agents[index]
            AgentAvatarView(
                agentId: agent.id,
                size: size,
                specialist: agent.specialist,
                state: AgentAvatarState.state(for: agent),
                workspaceStyle: true
            )
        } else {
            Image(.agents)
                .resizable()
                .scaledToFit()
                .frame(width: size * WorkspaceDetailStyle.avatarArtRatio, height: size * WorkspaceDetailStyle.avatarArtRatio)
                .foregroundStyle(WorkspaceDetailStyle.avatarForeground(for: colorScheme))
                .frame(width: size, height: size)
                .background(WorkspaceDetailStyle.avatarSurface(for: colorScheme))
                .accessibilityHidden(true)
        }
    }
}

nonisolated private struct AgentAvatarStrokeShape: Shape {
    let glyphPath: Path

    func path(in rect: CGRect) -> Path {
        glyphPath.applying(artTransform(for: rect))
    }
}

nonisolated private struct AgentAvatarFillShape: Shape {
    let glyphPath: Path

    func path(in rect: CGRect) -> Path {
        glyphPath.applying(artTransform(for: rect))
    }
}

/// Maps the 16×16 glyph art space onto the shape's rect.
nonisolated private func artTransform(for rect: CGRect) -> CGAffineTransform {
    CGAffineTransform(translationX: rect.minX, y: rect.minY)
        .scaledBy(
            x: rect.width / Constants.AgentAvatar.referenceArtSize,
            y: rect.height / Constants.AgentAvatar.referenceArtSize
        )
}
