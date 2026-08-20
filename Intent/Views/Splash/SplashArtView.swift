import SwiftUI

/// Full-screen renderer for `SplashArtModel`, matching the cloudlands splash
/// (`app.html` #splash-art): a `TimelineView(.animation)`-driven `Canvas`
/// strokes the routes during the eased intro reveal, then draws per-tile
/// curves with ambient and touch-driven flips. 2px round-cap strokes in the
/// theme foreground on the theme background. Under Reduce Motion the
/// completed pattern renders once, statically, with no animation loop.
struct SplashArtView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renderer = SplashArtRenderer()
    @State private var touchActive = false

    var body: some View {
        ZStack {
            Theme.background(for: colorScheme)
            if reduceMotion {
                // Single static draw: introProgress is forced to 1 and no
                // flips are scheduled, so nothing requests another frame.
                Canvas { context, size in
                    renderer.draw(
                        into: &context, size: size, now: Self.nowMilliseconds(),
                        reducedMotion: true, lineColor: Theme.foreground(for: colorScheme))
                }
            } else {
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        renderer.draw(
                            into: &context, size: size,
                            now: timeline.date.timeIntervalSinceReferenceDate * 1000,
                            reducedMotion: false,
                            lineColor: Theme.foreground(for: colorScheme))
                    }
                }
                .contentShape(Rectangle())
                .gesture(flipGesture)
            }
        }
        .ignoresSafeArea()
    }

    /// Touch parity with app.html's pointer handlers: the initial touch acts
    /// as pointerdown (reach 1.8 × min cell), subsequent drag movement as
    /// pointermove (reach 0.72 × min cell). The model itself gates flips
    /// until the intro reveal completes.
    private var flipGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let factor = SplashArtRenderer.reachFactor(isInitialTouch: !touchActive)
                touchActive = true
                renderer.flipNear(
                    location: value.location, reachFactor: factor,
                    now: Self.nowMilliseconds())
            }
            .onEnded { _ in touchActive = false }
    }

    /// Same clock as the `TimelineView` dates, in the model's millisecond units.
    private static func nowMilliseconds() -> Double {
        Date().timeIntervalSinceReferenceDate * 1000
    }
}

/// Holds the splash model plus precomputed tile paths and performs the
/// per-frame Canvas drawing. A class (kept in `@State`) so the imperative
/// flip/reveal state survives view updates without triggering them; the
/// redraw loop is owned entirely by `TimelineView`, so there are no timers
/// to clean up when the view disappears.
final class SplashArtRenderer {
    private(set) var model: SplashArtModel?
    /// Tile-local stroke paths indexed by orientation; every tile shares the
    /// same cell size, so two paths cover all tiles (rebuilt on size change).
    private var tilePaths: [Path] = []
    private let strokeStyle = StrokeStyle(lineWidth: 2, lineCap: .round)
    private let seed = UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970 * 1000))

    // MARK: - Drawing

    func draw(
        into context: inout GraphicsContext, size: CGSize, now: Double,
        reducedMotion: Bool, lineColor: Color
    ) {
        rebuildIfNeeded(size: size, now: now)
        guard let model, !model.routes.isEmpty else { return }
        let intro = model.introProgress(at: now, reducedMotion: reducedMotion)
        if intro < 1 {
            let traveled = SplashArtModel.ease(intro) * model.maxRouteLength
            for route in model.routes {
                strokeRoute(
                    route, progress: min(1, traveled / route.totalLength),
                    into: &context, lineColor: lineColor)
            }
        } else {
            drawInteractiveTiles(
                now: now, reducedMotion: reducedMotion, into: &context, lineColor: lineColor)
        }
    }

    /// Mirrors app.html's `draw()` size check: (re)builds the model when the
    /// canvas size changes, restarting the intro reveal (the model's rng
    /// carries over across rebuilds, like the JS `seed` variable).
    private func rebuildIfNeeded(size: CGSize, now: Double) {
        let width = Double(size.width)
        let height = Double(size.height)
        if model == nil {
            model = SplashArtModel(width: width, height: height, seed: seed)
        } else if model!.width != width.rounded() || model!.height != height.rounded() {
            model!.rebuild(width: width, height: height)
        } else {
            return
        }
        model!.startReveal(at: now)
        tilePaths = [0, 1].map { orient in
            Self.tilePath(
                rx: model!.cellWidth / 2, ry: model!.cellHeight / 2, orient: orient)
        }
    }

    /// Strokes the leading portion of a route (all 7 concentric curves of
    /// every segment up to `progress` of the total length) as one path.
    private func strokeRoute(
        _ route: SplashArtModel.Route, progress: Double,
        into context: inout GraphicsContext, lineColor: Color
    ) {
        let endDistance = route.totalLength * progress
        var path = Path()
        for segment in route.segments {
            guard let span = Self.visibleSpan(
                offset: segment.offset, length: segment.length, endDistance: endDistance)
            else { continue }
            let startAngle = segment.startAngle + segment.angleDelta * span.start
            let endAngle = segment.startAngle + segment.angleDelta * span.end
            for curveIndex in 0..<SplashArtModel.curvesPerTile {
                // Unit-circle arc mapped onto the ellipse by an affine
                // transform (same geometry as the canvas `ellipse()` call).
                let transform = CGAffineTransform(translationX: segment.cx, y: segment.cy)
                    .scaledBy(
                        x: SplashArtModel.curveRadius(segment.rx, curveIndex),
                        y: SplashArtModel.curveRadius(segment.ry, curveIndex))
                path.move(to: CGPoint(x: cos(startAngle), y: sin(startAngle)).applying(transform))
                path.addArc(
                    center: .zero, radius: 1,
                    startAngle: .radians(startAngle), endAngle: .radians(endAngle),
                    clockwise: segment.angleDelta < 0, transform: transform)
            }
        }
        if !path.isEmpty {
            context.stroke(path, with: .color(lineColor), style: strokeStyle)
        }
    }

    /// Interactive phase: runs the ambient flip scheduler (skipped under
    /// reduced motion), then draws every tile clipped to its rect, rotated
    /// by its eased mid-flip angle. Mirrors `drawInteractiveTiles(now)`.
    private func drawInteractiveTiles(
        now: Double, reducedMotion: Bool,
        into context: inout GraphicsContext, lineColor: Color
    ) {
        if !reducedMotion {
            model?.ambientFlipIfDue(now: now)
        }
        guard let modelSnapshot = model, tilePaths.count == 2 else { return }
        for index in modelSnapshot.tiles.indices {
            // flipAngle advances the flip state (a finished flip toggles the
            // tile's orientation), so re-read the tile after calling it.
            let angle = reducedMotion ? 0 : (model?.flipAngle(tileIndex: index, now: now) ?? 0)
            guard let tile = model?.tiles[index] else { continue }
            var tileContext = context
            tileContext.clip(to: Path(CGRect(
                x: tile.cx - tile.rx, y: tile.cy - tile.ry,
                width: tile.rx * 2, height: tile.ry * 2)))
            tileContext.translateBy(x: tile.cx, y: tile.cy)
            if angle != 0 {
                tileContext.rotate(by: .radians(angle))
            }
            tileContext.stroke(tilePaths[tile.orient], with: .color(lineColor), style: strokeStyle)
        }
    }

    // MARK: - Touch

    func flipNear(location: CGPoint, reachFactor: Double, now: Double) {
        guard let cellWidth = model?.cellWidth, let cellHeight = model?.cellHeight else { return }
        model?.flipNear(
            x: Double(location.x), y: Double(location.y),
            reach: min(cellWidth, cellHeight) * reachFactor, now: now)
    }

    /// app.html registers pointerdown with reach 1.8 × min cell and
    /// pointermove with 0.72 ×; the first touch of a gesture is the "down".
    static func reachFactor(isInitialTouch: Bool) -> Double {
        isInitialTouch ? SplashArtModel.tapReachFactor : SplashArtModel.hoverReachFactor
    }

    // MARK: - Geometry helpers

    /// Fraction window (0…1 along the segment's arc) visible when a route is
    /// stroked from distance 0 to `endDistance`; nil when the segment lies
    /// entirely outside the revealed span. Mirrors the clamping in
    /// app.html's `strokeRoute`.
    static func visibleSpan(
        offset: Double, length: Double, endDistance: Double
    ) -> (start: Double, end: Double)? {
        let start = max(0, (0 - offset) / length)
        let end = min(1, (endDistance - offset) / length)
        if end <= 0 || start >= 1 || start >= end { return nil }
        return (start, end)
    }

    /// Tile-local (origin at tile center) stroke path for one orientation:
    /// 7 concentric quarter-ellipse pairs centered on opposite corners.
    /// Mirrors `strokeTile` + `addTileCurve` in app.html.
    private static func tilePath(rx: Double, ry: Double, orient: Int) -> Path {
        var path = Path()
        for curveIndex in 0..<SplashArtModel.curvesPerTile {
            let curveRx = SplashArtModel.curveRadius(rx, curveIndex)
            let curveRy = SplashArtModel.curveRadius(ry, curveIndex)
            if orient == 0 {
                addTileCurve(&path, cx: -rx, cy: -ry, rx: curveRx, ry: curveRy,
                             startAngle: 0, endAngle: .pi / 2)
                addTileCurve(&path, cx: rx, cy: ry, rx: curveRx, ry: curveRy,
                             startAngle: .pi, endAngle: .pi * 1.5)
            } else {
                addTileCurve(&path, cx: rx, cy: -ry, rx: curveRx, ry: curveRy,
                             startAngle: .pi / 2, endAngle: .pi)
                addTileCurve(&path, cx: -rx, cy: ry, rx: curveRx, ry: curveRy,
                             startAngle: .pi * 1.5, endAngle: .pi * 2)
            }
        }
        return path
    }

    private static func addTileCurve(
        _ path: inout Path, cx: Double, cy: Double, rx: Double, ry: Double,
        startAngle: Double, endAngle: Double
    ) {
        let transform = CGAffineTransform(translationX: cx, y: cy).scaledBy(x: rx, y: ry)
        path.move(to: CGPoint(x: cos(startAngle), y: sin(startAngle)).applying(transform))
        path.addArc(
            center: .zero, radius: 1,
            startAngle: .radians(startAngle), endAngle: .radians(endAngle),
            clockwise: false, transform: transform)
    }
}

#Preview("Splash art") {
    SplashArtView()
}

#Preview("Splash art - Dark") {
    SplashArtView()
        .preferredColorScheme(.dark)
}
