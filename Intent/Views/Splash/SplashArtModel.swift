import Foundation

/// Seeded LCG matching the cloudlands splash RNG (`app.html` #splash-art IIFE):
/// `seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; seed / 2^32`.
/// UInt32 overflow arithmetic reproduces JS's int32 multiply + `>>> 0` exactly.
struct SplashRandom {
    var seed: UInt32

    mutating func next() -> Double {
        seed = seed &* Constants.Splash.Random.multiplier &+ Constants.Splash.Random.increment
        return Double(seed) / Constants.Splash.Random.normalizationDivisor
    }
}

/// Pure-Swift port of the non-rendering parts of the cloudlands splash
/// algorithm (`packages/cloudlands-fe/src/app.html`, the #splash-art script):
/// tile grid sizing, quarter-ellipse Truchet segment geometry, route tracing,
/// best-coverage layout search, and ambient/interactive flip state.
/// Deterministic for a given seed + size; contains no drawing code.
struct SplashArtModel {
    // MARK: - Constants (mirroring app.html)

    static let curvesPerTile = 7
    static let curveSpacing = 0.12
    static let introDuration: Double = 2200
    static let initialRevealProgress = 0.12
    static let flipDuration: Double = 420
    /// Reach factors for flips, in multiples of min(cellWidth, cellHeight):
    /// ambient burst 1.4, pointer move 0.72, pointer down (tap) 1.8.
    static let ambientReachFactor = 1.4
    static let hoverReachFactor = 0.72
    static let tapReachFactor = 1.8
    /// app.html tries 1200 random layouts; capped at 300 here to keep the
    /// search mobile-friendly (coverage remains acceptable — the early-exit
    /// full-coverage layout is usually found well before 300 attempts).
    static let maxLayoutAttempts = 300

    // MARK: - Types

    struct Point: Equatable {
        var x: Double
        var y: Double
    }

    struct Tile {
        let col: Int
        let row: Int
        let cx: Double
        let cy: Double
        let rx: Double
        let ry: Double
        var orient: Int = 0
        var flipStart: Double = -1
        var lastFlip: Double = -.infinity
    }

    /// One quarter-ellipse arc across a tile, from the entry port's edge
    /// midpoint to the exit port's. Ports: 0 = top, 1 = right, 2 = bottom,
    /// 3 = left.
    struct Segment {
        let cx: Double
        let cy: Double
        let rx: Double
        let ry: Double
        let col: Int
        let row: Int
        let startAngle: Double
        let angleDelta: Double
        let length: Double
        let entryPort: Int
        let exitPort: Int
        var key: String = ""
        var offset: Double = 0
    }

    struct Route {
        var segments: [Segment]
        var totalLength: Double
    }

    struct Coverage {
        var columnsCovered: Int
        var rowsCovered: Int
        var score: Double
    }

    // MARK: - State

    private(set) var rng: SplashRandom
    private(set) var width: Double = 0
    private(set) var height: Double = 0
    private(set) var columns: Int = 0
    private(set) var rows: Int = 0
    private(set) var cellWidth: Double = 0
    private(set) var cellHeight: Double = 0
    private(set) var tiles: [Tile] = []
    private(set) var routes: [Route] = []
    private(set) var maxRouteLength: Double = 1
    private(set) var revealStartedAt: Double = 0
    private(set) var nextAmbientFlip: Double = .infinity

    init(width: Double, height: Double, seed: UInt32) {
        rng = SplashRandom(seed: seed)
        rebuild(width: width, height: height)
    }

    // MARK: - Grid

    /// `columns = max(4, round(width / 150))`,
    /// `rows = max(6, round(height / width * columns))`.
    static func gridSize(width: Double, height: Double) -> (columns: Int, rows: Int) {
        let columns = max(Constants.Splash.minimumColumns,
                          Int((width / Constants.Splash.targetCellWidth).rounded()))
        let rows = max(Constants.Splash.minimumRows,
                       Int(((height / width) * Double(columns)).rounded()))
        return (columns, rows)
    }

    mutating func rebuild(width rawWidth: Double, height rawHeight: Double) {
        width = rawWidth.rounded()
        height = rawHeight.rounded()
        tiles = []
        routes = []
        maxRouteLength = 1
        guard width > 0, height > 0 else {
            columns = 0
            rows = 0
            cellWidth = 0
            cellHeight = 0
            return
        }
        let grid = Self.gridSize(width: width, height: height)
        columns = grid.columns
        rows = grid.rows
        cellWidth = width / Double(columns)
        cellHeight = height / Double(rows)
        for row in 0..<rows {
            for col in 0..<columns {
                tiles.append(Tile(
                    col: col,
                    row: row,
                    cx: (Double(col) + 0.5) * cellWidth,
                    cy: (Double(row) + 0.5) * cellHeight,
                    rx: cellWidth / 2,
                    ry: cellHeight / 2))
            }
        }
        buildFullWindowRoute()
    }

    // MARK: - Geometry

    static func ease(_ progress: Double) -> Double {
        1 - pow(1 - progress, 3)
    }

    /// Edge midpoint of a tile for a port (0 top, 1 right, 2 bottom, 3 left).
    static func portPoint(_ tile: Tile, _ port: Int) -> Point {
        switch port {
        case 0: return Point(x: tile.cx, y: tile.cy - tile.ry)
        case 1: return Point(x: tile.cx + tile.rx, y: tile.cy)
        case 2: return Point(x: tile.cx, y: tile.cy + tile.ry)
        default: return Point(x: tile.cx - tile.rx, y: tile.cy)
        }
    }

    /// Quarter-ellipse arc between two port midpoints, centered on the tile
    /// corner shared by the two ports.
    static func makeSegment(_ tile: Tile, from: Int, to: Int) -> Segment {
        let fromPoint = portPoint(tile, from)
        let toPoint = portPoint(tile, to)
        let centerX = (from == 1 || to == 1) ? tile.cx + tile.rx : tile.cx - tile.rx
        let centerY = (from == 2 || to == 2) ? tile.cy + tile.ry : tile.cy - tile.ry
        func angleAt(_ point: Point) -> Double {
            atan2((point.y - centerY) / tile.ry, (point.x - centerX) / tile.rx)
        }
        let startAngle = angleAt(fromPoint)
        var angleDelta = angleAt(toPoint) - startAngle
        while angleDelta > .pi { angleDelta -= .pi * 2 }
        while angleDelta < -.pi { angleDelta += .pi * 2 }
        return Segment(
            cx: centerX,
            cy: centerY,
            rx: tile.rx,
            ry: tile.ry,
            col: tile.col,
            row: tile.row,
            startAngle: startAngle,
            angleDelta: angleDelta,
            length: (.pi / 2) * ((tile.rx * tile.rx + tile.ry * tile.ry) / 2).squareRoot(),
            entryPort: from,
            exitPort: to)
    }

    /// Radius of one of the 7 concentric curves: the middle curve (index 3)
    /// sits exactly on the half extent, neighbors step by 0.12 of it.
    static func curveRadius(_ halfExtent: Double, _ curveIndex: Int) -> Double {
        let centeredIndex = Double(curveIndex) - Double(curvesPerTile - 1) / 2
        return halfExtent * (1 + centeredIndex * curveSpacing)
    }

    static func pointOnSegment(_ segment: Segment, progress: Double, curveIndex: Int) -> Point {
        let angle = segment.startAngle + segment.angleDelta * progress
        return Point(
            x: segment.cx + cos(angle) * curveRadius(segment.rx, curveIndex),
            y: segment.cy + sin(angle) * curveRadius(segment.ry, curveIndex))
    }

    static func oppositePort(_ port: Int) -> Int {
        (port + 2) % 4
    }

    /// Which port an entry port connects to for a tile orientation:
    /// orient 0 pairs top↔left and right↔bottom, orient 1 pairs top↔right
    /// and bottom↔left.
    static func pairedPort(orient: Int, port: Int) -> Int {
        orient == 0 ? [3, 2, 1, 0][port] : [1, 0, 3, 2][port]
    }

    // MARK: - Routes

    /// One tile-to-tile step of a traced route, before any segment geometry
    /// is built.
    typealias RouteStep = (tileIndex: Int, entryPort: Int, exitPort: Int)

    /// Follows the route tile-to-tile from a starting tile + entry port until
    /// it leaves the grid or revisits a (tile, port) pair, returning raw
    /// steps only. The layout search runs on these (it just needs coverage),
    /// skipping `makeSegment`'s trig and any string allocation on its hot
    /// path: the visit key packs (tile, port) into an Int.
    func traceRouteSteps(startIndex: Int, startPort: Int) -> [RouteStep] {
        var steps: [RouteStep] = []
        var visited = Set<Int>()
        var tileIndex = startIndex
        var entryPort = startPort
        while true {
            let visitKey = tileIndex << 2 | entryPort
            if visited.contains(visitKey) { break }
            visited.insert(visitKey)
            let tile = tiles[tileIndex]
            let exitPort = Self.pairedPort(orient: tile.orient, port: entryPort)
            steps.append((tileIndex, entryPort, exitPort))
            let nextCol = tile.col + (exitPort == 1 ? 1 : exitPort == 3 ? -1 : 0)
            let nextRow = tile.row + (exitPort == 2 ? 1 : exitPort == 0 ? -1 : 0)
            if nextCol < 0 || nextCol >= columns || nextRow < 0 || nextRow >= rows { break }
            tileIndex = nextRow * columns + nextCol
            entryPort = Self.oppositePort(exitPort)
        }
        return steps
    }

    /// Follows arcs tile-to-tile from a starting tile + entry port until the
    /// route leaves the grid or revisits a (tile, port) pair.
    func traceRoute(startIndex: Int, startPort: Int) -> [Segment] {
        traceRouteSteps(startIndex: startIndex, startPort: startPort).map { step in
            var segment = Self.makeSegment(
                tiles[step.tileIndex], from: step.entryPort, to: step.exitPort)
            segment.key = "\(step.tileIndex):"
                + "\(min(step.entryPort, step.exitPort))-\(max(step.entryPort, step.exitPort))"
            return segment
        }
    }

    /// Longest route (as raw steps) reachable from any boundary port under
    /// the current tile orientations.
    func longestRouteStepsForLayout() -> [RouteStep] {
        var starts: [(Int, Int)] = []
        for col in 0..<columns {
            starts.append((col, 0))
            starts.append(((rows - 1) * columns + col, 2))
        }
        for row in 0..<rows {
            starts.append((row * columns, 3))
            starts.append((row * columns + columns - 1, 1))
        }
        var longest: [RouteStep] = []
        for (tileIndex, port) in starts {
            let candidate = traceRouteSteps(startIndex: tileIndex, startPort: port)
            if candidate.count > longest.count { longest = candidate }
        }
        return longest
    }

    func routeCoverage(_ candidate: [RouteStep]) -> Coverage {
        let columnsCovered = Set(candidate.map { tiles[$0.tileIndex].col }).count
        let rowsCovered = Set(candidate.map { tiles[$0.tileIndex].row }).count
        let score = (Double(columnsCovered) / Double(columns))
            * (Double(rowsCovered) / Double(rows)) * Constants.Splash.routeCoverageWeight
            + Double(candidate.count)
        return Coverage(columnsCovered: columnsCovered, rowsCovered: rowsCovered, score: score)
    }

    /// Traces routes from every boundary port, then from every interior
    /// (tile, port), claiming segments by key so no arc is stroked twice.
    mutating func buildAllRoutes() {
        var claimed = Set<String>()
        routes = []
        func addRoute(_ tileIndex: Int, _ port: Int) {
            var candidate = traceRoute(startIndex: tileIndex, startPort: port)
            guard let first = candidate.first, !claimed.contains(first.key) else { return }
            var offset = 0.0
            for index in candidate.indices {
                claimed.insert(candidate[index].key)
                candidate[index].offset = offset
                offset += candidate[index].length
            }
            routes.append(Route(segments: candidate, totalLength: offset))
        }
        for col in 0..<columns {
            addRoute(col, 0)
            addRoute((rows - 1) * columns + col, 2)
        }
        for row in 0..<rows {
            addRoute(row * columns, 3)
            addRoute(row * columns + columns - 1, 1)
        }
        for tileIndex in tiles.indices {
            for port in 0..<4 { addRoute(tileIndex, port) }
        }
        maxRouteLength = max(routes.map(\.totalLength).max() ?? 1, 1)
    }

    /// Best-coverage layout search: randomizes tile orientations up to
    /// `maxLayoutAttempts` times, keeping the layout whose longest route
    /// scores best; stops early on full column+row coverage with a route of
    /// at least 65% of the tile count. The search traces raw steps only —
    /// the winning layout's segment geometry is built by `buildAllRoutes`.
    mutating func buildFullWindowRoute() {
        var bestRoute: [RouteStep] = []
        var bestOrientations: [Int] = []
        var bestScore = -1.0
        let targetLength = Int(
            (Double(tiles.count) * Constants.Splash.targetRouteCoverage).rounded(.down))
        for _ in 0..<Self.maxLayoutAttempts {
            for index in tiles.indices {
                tiles[index].orient = rng.next() > 0.5 ? 1 : 0
            }
            let candidate = longestRouteStepsForLayout()
            let coverage = routeCoverage(candidate)
            if coverage.score > bestScore {
                bestRoute = candidate
                bestOrientations = tiles.map(\.orient)
                bestScore = coverage.score
            }
            if coverage.columnsCovered == columns && coverage.rowsCovered == rows
                && candidate.count >= targetLength {
                break
            }
        }
        guard !bestRoute.isEmpty else { return }
        for index in tiles.indices {
            tiles[index].orient = bestOrientations[index]
        }
        buildAllRoutes()
    }

    // MARK: - Reveal & flip state

    /// Anchors the intro reveal at `now` and schedules the first ambient flip
    /// (app.html does this with `performance.now()` when a layout is built;
    /// kept explicit here so the model stays clock-free and deterministic).
    mutating func startReveal(at now: Double) {
        revealStartedAt = now
        nextAmbientFlip = now + Self.introDuration + Constants.Splash.firstAmbientDelay
    }

    /// Eased 0…1 intro progress at `now`; 1 when reduced motion is on.
    func introProgress(at now: Double, reducedMotion: Bool) -> Double {
        if reducedMotion { return 1 }
        return min(
            1,
            Self.initialRevealProgress
                + (max(0, now - revealStartedAt) / Self.introDuration)
                * (1 - Self.initialRevealProgress))
    }

    /// Ambient flip pass: when due, picks a random anchor tile and schedules
    /// distance-staggered flips on tiles within 1.4 cells of it, then
    /// reschedules itself 1100–2600ms out.
    mutating func ambientFlipIfDue(now: Double) {
        guard now >= nextAmbientFlip else { return }
        let anchorIndex = Int((rng.next() * Double(tiles.count)).rounded(.down))
        if anchorIndex >= 0 && anchorIndex < tiles.count {
            let anchor = tiles[anchorIndex]
            let reach = min(cellWidth, cellHeight) * Self.ambientReachFactor
            for index in tiles.indices {
                let distance = hypot(tiles[index].cx - anchor.cx, tiles[index].cy - anchor.cy)
                if tiles[index].flipStart < 0 && distance < reach {
                    tiles[index].flipStart = now + distance * Constants.Splash.ambientStagger
                }
            }
        }
        nextAmbientFlip = now + Constants.Splash.minimumAmbientInterval
            + rng.next() * Constants.Splash.ambientIntervalRange
    }

    /// Pointer/touch flip: schedules flips on settled tiles within `reach` of
    /// (x, y), staggered by distance. No-op until the intro reveal completes.
    mutating func flipNear(x: Double, y: Double, reach: Double, now: Double) {
        guard now - revealStartedAt >= Self.introDuration else { return }
        for index in tiles.indices {
            let distance = hypot(tiles[index].cx - x, tiles[index].cy - y)
            if tiles[index].flipStart < 0
                && now - tiles[index].lastFlip > Constants.Splash.repeatFlipCooldown
                && distance < reach {
                tiles[index].flipStart = now + distance * Constants.Splash.interactiveStagger
            }
        }
    }

    /// Current flip rotation for a tile, advancing its flip state: a finished
    /// flip toggles the orientation and records `lastFlip`; a flip in progress
    /// returns the eased angle (0…π/2).
    mutating func flipAngle(tileIndex: Int, now: Double) -> Double {
        guard tiles[tileIndex].flipStart >= 0 else { return 0 }
        let progress = (now - tiles[tileIndex].flipStart) / Self.flipDuration
        if progress >= 1 {
            tiles[tileIndex].orient ^= 1
            tiles[tileIndex].flipStart = -1
            tiles[tileIndex].lastFlip = now
            return 0
        }
        if progress > 0 {
            return Self.ease(progress) * (.pi / 2)
        }
        return 0
    }
}
