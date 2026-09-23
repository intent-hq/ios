import SwiftUI

/// Rounded-tile agent avatar with the desktop app's monochrome stroke glyphs.
/// Ported from cloudlands-fe `AgentAvatar.svelte` + `AgentAvatarArt.svelte`:
/// glyphs are stroked in a 16×16 art box (stroke width 1.33, round caps and
/// joins) centered on a rounded tile whose surface is colored by `state`
/// (`AgentAvatarWithState.svelte`); the default `.idle` keeps the neutral tile.
struct AgentAvatarView: View {
    let agentId: String
    var size: CGFloat = Constants.AgentAvatar.defaultSize
    var specialist: String?
    var icon: String?  // Specialist icon metadata (PROTOCOL §5.11)
    var isActive: Bool = false
    var state: AgentAvatarState = .idle

    private var design: AgentAvatarDesign {
        AgentAvatarDesign.design(agentId: agentId, specialist: specialist, icon: icon)
    }

    // Desktop geometry ratios (avatar-size.ts "standard": surface 20,
    // art 16, clear space 2, corner radius 6).
    private var artSize: CGFloat { size * Constants.AgentAvatar.artSizeRatio }
    private var cornerRadius: CGFloat { size * Constants.AgentAvatar.cornerRadiusRatio }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(surfaceColor)

            AgentAvatarStrokeShape(glyphPath: design.glyph.strokePath)
                .stroke(glyphColor, style: StrokeStyle(
                    lineWidth: Constants.AgentAvatar.referenceStrokeWidth * artSize
                        / Constants.AgentAvatar.referenceArtSize,
                    lineCap: .round,
                    lineJoin: .round
                ))
                .frame(width: artSize, height: artSize)

            AgentAvatarFillShape(glyphPath: design.glyph.fillPath)
                .fill(glyphColor)
                .frame(width: artSize, height: artSize)

            // Active pulsing indicator. Each phase is a finite ease-in-out
            // animation on the stroke color only — a `repeatForever` implicit
            // animation here leaked into the ring's geometry whenever the row
            // moved in a reordering list, leaving rings oscillating between rows.
            if isActive {
                PhaseAnimator([false, true]) { strong in
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(
                            strong
                                ? Constants.Colors.AgentAvatar.activeStrokeStrong
                                : Constants.Colors.AgentAvatar.activeStrokeWeak,
                            lineWidth: Constants.AgentAvatar.activeStrokeWidth
                        )
                } animation: { _ in
                    .easeInOut(duration: Constants.AgentAvatar.pulseAnimationDuration)
                }
            }
        }
        .frame(width: size, height: size)
        .geometryGroup()
    }

    /// Desktop tile surface per state (`--agent-avatar-surface-*` tokens);
    /// idle is the neutral hsl(145 14% 92%) light / hsl(145 12% 78%) dark.
    private var surfaceColor: Color {
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
        state == .completed
            ? Constants.Colors.AgentAvatar.glyphCompleted
            : Constants.Colors.AgentAvatar.glyph
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
