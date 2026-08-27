import SwiftUI

/// Rounded-tile agent avatar with the desktop app's monochrome stroke glyphs.
/// Ported from cloudlands-fe `AgentAvatar.svelte` + `AgentAvatarArt.svelte`:
/// glyphs are stroked in a 16×16 art box (stroke width 1.33, round caps and
/// joins) centered on a rounded neutral tile.
struct AgentAvatarView: View {
    let agentId: String
    var size: CGFloat = 20
    var specialist: String? = nil
    var icon: String? = nil  // Specialist icon metadata (PROTOCOL §5.11)
    var isActive: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @State private var isPulsing = false

    private var design: AgentAvatarDesign {
        AgentAvatarDesign.design(agentId: agentId, specialist: specialist, icon: icon)
    }

    // Desktop geometry ratios (avatar-size.ts "standard": surface 20,
    // art 16, clear space 2, corner radius 6).
    private var artSize: CGFloat { size * 0.8 }
    private var cornerRadius: CGFloat { size * 0.3 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(surfaceColor)

            AgentAvatarStrokeShape(glyphPath: design.glyph.strokePath)
                .stroke(glyphColor, style: StrokeStyle(
                    lineWidth: 1.33 * artSize / 16, lineCap: .round, lineJoin: .round))
                .frame(width: artSize, height: artSize)

            AgentAvatarFillShape(glyphPath: design.glyph.fillPath)
                .fill(glyphColor)
                .frame(width: artSize, height: artSize)

            // Active pulsing indicator
            if isActive {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.green.opacity(isPulsing ? 0.6 : 0.2), lineWidth: 1.5)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isPulsing)
                    .onAppear { isPulsing = true }
            }
        }
        .frame(width: size, height: size)
    }

    /// Desktop neutral tile surface (`--agent-avatar-surface-neutral`):
    /// hsl(145 14% 92%) light / hsl(145 12% 78%) dark.
    private var surfaceColor: Color {
        colorScheme == .dark
            ? Color(red: 0.754, green: 0.806, blue: 0.784)
            : Color(red: 0.909, green: 0.931, blue: 0.922)
    }

    /// Desktop glyph color: near-black (#080808) in both schemes — the tile
    /// stays light, so the glyph stays dark.
    private var glyphColor: Color { Color(white: 0.03) }
}

private struct AgentAvatarStrokeShape: Shape {
    let glyphPath: Path

    func path(in rect: CGRect) -> Path {
        glyphPath.applying(artTransform(for: rect))
    }
}

private struct AgentAvatarFillShape: Shape {
    let glyphPath: Path

    func path(in rect: CGRect) -> Path {
        glyphPath.applying(artTransform(for: rect))
    }
}

/// Maps the 16×16 glyph art space onto the shape's rect.
nonisolated private func artTransform(for rect: CGRect) -> CGAffineTransform {
    CGAffineTransform(translationX: rect.minX, y: rect.minY)
        .scaledBy(x: rect.width / 16, y: rect.height / 16)
}
