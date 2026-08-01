import SwiftUI

// MARK: - Seeded Random Number Generator

/// Deterministic RNG seeded from an integer — produces stable positions per agent.
struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: Int) {
        state = UInt64(bitPattern: Int64(seed))
        // Warm up the state
        for _ in 0..<5 { _ = next() }
    }

    mutating func next() -> UInt64 {
        // xorshift64
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

// MARK: - Star data

/// A single star dot — position is in 0…1 normalized coordinates.
struct StarDot: Identifiable {
    let id: Int
    let x: CGFloat        // 0…1
    let y: CGFloat        // 0…1
    let size: CGFloat     // radius in pt (power-law: 0.5–3.0)
    let baseOpacity: CGFloat  // base opacity before shimmer
    let phase: Double     // shimmer phase offset (0…1)
    let shimmerAmplitude: CGFloat // how much shimmer affects opacity
    let colorMix: CGFloat // 0 = white, 1 = agent color
}

// MARK: - Per-agent star cluster

/// Renders one agent's star cluster. Stars fade in when active, shimmer, fade out when inactive.
struct AgentStarCluster: View {
    let agentId: String
    let color: Color
    let isActive: Bool
    let isDarkMode: Bool
    var isTransitioning: Bool = false

    @State private var opacity: Double = 0.0

    /// Nebula center in 0…1 coords, seeded per agent.
    private var nebulaCenter: CGPoint {
        var rng = SeededRandomNumberGenerator(seed: Int((RepoColorSystem.stableHash(agentId) &+ 9999) & 0x7FFFFFFFFFFFFFFF))
        let nx = CGFloat.random(in: 0.2...0.8, using: &rng)
        let ny = CGFloat.random(in: 0.2...0.8, using: &rng)
        return CGPoint(x: nx, y: ny)
    }

    var stars: [StarDot] {
        var rng = SeededRandomNumberGenerator(seed: Int(RepoColorSystem.stableHash(agentId) & 0x7FFFFFFFFFFFFFFF))
        let count = 120
        return (0..<count).map { i in
            let rawSize = CGFloat.random(in: 0...1, using: &rng)
            let size = 0.5 + pow(rawSize, 3.0) * 2.5

            // Opacity based on size tier
            let baseOpacity: CGFloat
            if size < 1.2 {
                baseOpacity = CGFloat.random(in: 0.3...0.7, using: &rng)
            } else if size < 1.5 {
                baseOpacity = CGFloat.random(in: 0.5...0.85, using: &rng)
            } else {
                baseOpacity = CGFloat.random(in: 0.7...1.0, using: &rng)
            }

            // Shimmer amplitude — ~20% of stars barely twinkle
            let shimmerRoll = CGFloat.random(in: 0...1, using: &rng)
            let shimmerAmplitude: CGFloat
            if shimmerRoll < 0.2 {
                // Nearly static
                shimmerAmplitude = CGFloat.random(in: 0.0...0.05, using: &rng)
            } else if size < 1.2 {
                shimmerAmplitude = CGFloat.random(in: 0.1...0.2, using: &rng)
            } else {
                shimmerAmplitude = CGFloat.random(in: 0.3...0.5, using: &rng)
            }

            // Color mix — tiny stars mostly white, bright stars more agent color
            let colorMix: CGFloat = size < 1.2
                ? CGFloat.random(in: 0.05...0.2, using: &rng)
                : CGFloat.random(in: 0.3...0.6, using: &rng)

            return StarDot(
                id: i,
                x: CGFloat.random(in: 0...1, using: &rng),
                y: CGFloat.random(in: 0...1, using: &rng),
                size: size,
                baseOpacity: baseOpacity,
                phase: Double.random(in: 0...1, using: &rng),
                shimmerAmplitude: shimmerAmplitude,
                colorMix: colorMix
            )
        }
    }

    var body: some View {
        GeometryReader { geo in
            if isTransitioning {
                // Frozen frame — no TimelineView overhead
                starCanvas(size: geo.size, time: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    starCanvas(size: geo.size, time: t)
                }
            }
        }
        .onChange(of: isActive) { _, newValue in
            print("[AgentStarCluster] onChange isActive=\(newValue) for \(agentId.prefix(8))...")
            withAnimation(.easeInOut(duration: newValue ? 1.0 : 1.5)) {
                opacity = newValue ? 1.0 : 0.0
            }
        }
        .onAppear {
            print("[AgentStarCluster] onAppear isActive=\(isActive) for \(agentId.prefix(8))...")
            opacity = isActive ? 1.0 : 0.0
        }
    }

    private func starCanvas(size: CGSize, time: Double) -> some View {
        let w = size.width
        let h = size.height
        let modeScale: CGFloat = isDarkMode ? 1.0 : 0.3
        let nc = nebulaCenter

        // Xcode 16.2's type checker times out on the inline closure
        // ("unable to type-check this expression in reasonable time"), so the
        // drawing body lives in drawCluster(in:w:h:time:modeScale:nc:).
        return Canvas { context, _ in
            drawCluster(in: &context, w: w, h: h, time: time, modeScale: modeScale, nc: nc)
        }
    }

    private func drawCluster(
        in context: inout GraphicsContext,
        w: CGFloat,
        h: CGFloat,
        time: Double,
        modeScale: CGFloat,
        nc: CGPoint
    ) {
        guard opacity > 0.01 else { return }

        // --- Faint nebula glow behind stars ---
        let nebulaRadius = min(w, h) * 0.4
        let nebulaPt = CGPoint(x: nc.x * w, y: nc.y * h)
        let nebulaRect = CGRect(
            x: nebulaPt.x - nebulaRadius,
            y: nebulaPt.y - nebulaRadius,
            width: nebulaRadius * 2,
            height: nebulaRadius * 2
        )
        context.opacity = opacity * Double(modeScale) * 0.05
        context.fill(Path(ellipseIn: nebulaRect), with: .radialGradient(
            Gradient(colors: [color.opacity(0.8), color.opacity(0.2), color.opacity(0)]),
            center: nebulaPt,
            startRadius: 0,
            endRadius: nebulaRadius
        ))

        // --- Stars ---
        for star in stars {
            let shimmerRate = 0.3 + star.phase * 0.5
            let shimmer = sin((time * shimmerRate * .pi * 2) + star.phase * .pi * 2)
            let shimmerFactor = 1.0 + CGFloat(shimmer) * star.shimmerAmplitude
            let finalOpacity = Double(star.baseOpacity * shimmerFactor * modeScale) * opacity

            guard finalOpacity > 0.005 else { continue }

            let center = CGPoint(x: star.x * w, y: star.y * h)

            // Blend star color: white mixed with agent color
            let starColor = Color(
                red: 1.0 * Double(1.0 - star.colorMix) + 0.8 * Double(star.colorMix),
                green: 1.0 * Double(1.0 - star.colorMix) + 0.85 * Double(star.colorMix),
                blue: 1.0 * Double(1.0 - star.colorMix) + 1.0 * Double(star.colorMix)
            )

            if star.size < 1.2 {
                // Tiny star: simple filled circle, no gradient
                let r = star.size
                let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                context.opacity = finalOpacity
                context.fill(Path(ellipseIn: rect), with: .color(starColor))
            } else {
                // Bright star: small solid core + faint halo
                let coreR = star.size * 0.6
                let haloR = star.size * 1.5

                // Halo first (behind core)
                let haloRect = CGRect(x: center.x - haloR, y: center.y - haloR, width: haloR * 2, height: haloR * 2)
                context.opacity = finalOpacity * 0.15
                context.fill(Path(ellipseIn: haloRect), with: .radialGradient(
                    Gradient(colors: [color.opacity(0.6), color.opacity(0.15), color.opacity(0)]),
                    center: center,
                    startRadius: 0,
                    endRadius: haloR
                ))

                // Solid core
                let coreRect = CGRect(x: center.x - coreR, y: center.y - coreR, width: coreR * 2, height: coreR * 2)
                context.opacity = finalOpacity
                context.fill(Path(ellipseIn: coreRect), with: .color(starColor))
            }
        }
        context.opacity = 1.0
    }
}

// MARK: - CoverflowBackgroundView

/// Star-field background: pure black/white when idle, per-agent star clusters when streaming.
struct CoverflowBackgroundView: View {
    @ObservedObject var store: CoverflowStore
    var isTransitioning: Bool = false
    @Environment(\.colorScheme) var colorScheme

    /// Pure background color — black in dark mode, white in light mode.
    private var pureBackground: Color {
        colorScheme == .dark ? .black : .white
    }

    var body: some View {
        ZStack {
            pureBackground
                .ignoresSafeArea()

            // One star cluster per agent in the queue
            ForEach(store.queue) { agent in
                let streaming = store.isAgentStreaming(agent.id)
                let _ = print("[CoverflowBG] Rendering cluster for \(agent.id.prefix(8))... isActive=\(streaming) queue.count=\(store.queue.count)")
                AgentStarCluster(
                    agentId: agent.id,
                    color: Color(
                        hue: Double(RepoColorSystem.stableHash(agent.workspaceId) % 360) / 360.0,
                        saturation: 0.5,
                        brightness: 0.85
                    ),
                    isActive: streaming,
                    isDarkMode: colorScheme == .dark,
                    isTransitioning: isTransitioning
                )
                .ignoresSafeArea()
            }
        }
    }
}

