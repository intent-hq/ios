import Foundation
import Testing
@testable import Intent

struct SplashArtModelTests {
    // MARK: - RNG

    @Test func rngMatchesJsLcgForSeed1() {
        var rng = SplashRandom(seed: 1)
        // Expected uint32 states of the JS LCG
        // (Math.imul(seed, 1664525) + 1013904223) >>> 0, starting from 1.
        let expectedStates: [UInt32] = [
            1_015_568_748, 1_586_005_467, 2_165_703_038, 3_027_450_565,
            217_083_232, 1_587_069_247, 3_327_581_586, 2_388_811_721,
        ]
        for expected in expectedStates {
            let value = rng.next()
            #expect(rng.seed == expected)
            #expect(value == Double(expected) / 4294967296)
        }
    }

    @Test func rngMatchesJsLcgForLargeSeed() {
        var rng = SplashRandom(seed: 123_456_789)
        let expectedStates: [UInt32] = [
            920_370_032, 3_761_641_487, 2_252_023_330, 1_475_571_481,
            2_340_457_892, 1_600_748_723, 1_240_767_094, 2_297_155_421,
        ]
        for expected in expectedStates {
            _ = rng.next()
            #expect(rng.seed == expected)
        }
    }

    // MARK: - Grid sizing

    @Test func gridSizingMatchesFormula() {
        // iPhone portrait: columns floor at 4, rows = round(844/390 * 4) = 9.
        #expect(SplashArtModel.gridSize(width: 390, height: 844) == (4, 9))
        // Wide: columns = round(750/150) = 5, rows floor at 6.
        #expect(SplashArtModel.gridSize(width: 750, height: 750) == (5, 6))
        // Tiny: both floors apply.
        #expect(SplashArtModel.gridSize(width: 100, height: 200) == (4, 8))
        // Landscape: columns = 8, rows = max(6, round(800/1200 * 8) = 5) = 6.
        #expect(SplashArtModel.gridSize(width: 1200, height: 800) == (8, 6))
    }

    @Test func rebuildPopulatesGrid() {
        let model = SplashArtModel(width: 390, height: 844, seed: 7)
        #expect(model.columns == 4)
        #expect(model.rows == 9)
        #expect(model.tiles.count == 36)
        #expect(model.cellWidth == 390.0 / 4)
        #expect(model.cellHeight == 844.0 / 9)
        let tile = model.tiles[model.columns + 1] // col 1, row 1
        #expect(tile.col == 1 && tile.row == 1)
        #expect(tile.cx == 1.5 * model.cellWidth)
        #expect(tile.cy == 1.5 * model.cellHeight)
    }

    // MARK: - Route tracing continuity

    @Test func routeSegmentsConnectContinuously() {
        let model = SplashArtModel(width: 390, height: 844, seed: 42)
        #expect(!model.routes.isEmpty)
        let middleCurve = (SplashArtModel.curvesPerTile - 1) / 2
        for route in model.routes {
            for (segment, next) in zip(route.segments, route.segments.dropFirst()) {
                // Next tile is the grid neighbor across the exit port…
                #expect(next.entryPort == SplashArtModel.oppositePort(segment.exitPort))
                #expect(abs(next.col - segment.col) + abs(next.row - segment.row) == 1)
                // …and the exit point coincides with the next entry point
                // (the middle of the 7 curves runs exactly through the
                // shared edge midpoint).
                let exit = SplashArtModel.pointOnSegment(
                    segment, progress: 1, curveIndex: middleCurve)
                let entry = SplashArtModel.pointOnSegment(
                    next, progress: 0, curveIndex: middleCurve)
                #expect(abs(exit.x - entry.x) < 1e-9)
                #expect(abs(exit.y - entry.y) < 1e-9)
            }
        }
    }

    @Test func segmentEndpointsAreTileEdgeMidpoints() throws {
        let model = SplashArtModel(width: 300, height: 900, seed: 5)
        let middleCurve = (SplashArtModel.curvesPerTile - 1) / 2
        let route = try #require(model.routes.first)
        for segment in route.segments {
            let tile = model.tiles[segment.row * model.columns + segment.col]
            let start = SplashArtModel.pointOnSegment(
                segment, progress: 0, curveIndex: middleCurve)
            let entry = SplashArtModel.portPoint(tile, segment.entryPort)
            #expect(abs(start.x - entry.x) < 1e-9)
            #expect(abs(start.y - entry.y) < 1e-9)
        }
    }

    // MARK: - buildAllRoutes

    @Test func buildAllRoutesClaimsEveryStartWithoutDuplicateKeys() {
        let model = SplashArtModel(width: 390, height: 844, seed: 99)
        let allSegments = model.routes.flatMap(\.segments)
        // No arc is claimed twice across all routes.
        let keys = allSegments.map(\.key)
        #expect(Set(keys).count == keys.count)
        // Every possible route start traces to an already-claimed first
        // segment — re-running addRoute for any (tile, port) adds nothing.
        let claimed = Set(keys)
        for tileIndex in model.tiles.indices {
            for port in 0..<4 {
                let candidate = model.traceRoute(startIndex: tileIndex, startPort: port)
                if let first = candidate.first {
                    #expect(claimed.contains(first.key))
                }
            }
        }
    }

    @Test func routeOffsetsAccumulateToTotalLength() {
        let model = SplashArtModel(width: 390, height: 844, seed: 12)
        for route in model.routes {
            var offset = 0.0
            for segment in route.segments {
                #expect(segment.offset == offset)
                offset += segment.length
            }
            #expect(route.totalLength == offset)
        }
        let maxTotal = model.routes.map(\.totalLength).max() ?? 1
        #expect(model.maxRouteLength == max(maxTotal, 1))
    }

    // MARK: - Determinism

    @Test func sameSeedAndSizeProducesIdenticalModel() {
        let a = SplashArtModel(width: 390, height: 844, seed: 2026)
        let b = SplashArtModel(width: 390, height: 844, seed: 2026)
        #expect(a.tiles.map(\.orient) == b.tiles.map(\.orient))
        #expect(a.routes.count == b.routes.count)
        #expect(a.routes.map { $0.segments.map(\.key) } == b.routes.map { $0.segments.map(\.key) })
        #expect(a.maxRouteLength == b.maxRouteLength)
        let c = SplashArtModel(width: 390, height: 844, seed: 2027)
        #expect(a.tiles.map(\.orient) != c.tiles.map(\.orient))
    }

    // MARK: - Flip state

    @Test func flipLifecycle() {
        var model = SplashArtModel(width: 390, height: 844, seed: 3)
        model.startReveal(at: 1000)
        #expect(model.nextAmbientFlip == 1000 + SplashArtModel.introDuration + 700)

        // Before the intro completes, interactive flips are ignored.
        let tile = model.tiles[0]
        model.flipNear(x: tile.cx, y: tile.cy, reach: 100, now: 1500)
        #expect(model.tiles[0].flipStart < 0)

        // After the intro, a nearby touch schedules a distance-staggered flip.
        let after = 1000 + SplashArtModel.introDuration
        model.flipNear(x: tile.cx, y: tile.cy, reach: 100, now: after)
        #expect(model.tiles[0].flipStart == after) // distance 0 → no stagger
        let originalOrient = model.tiles[0].orient

        // Mid-flip: eased angle in (0, π/2), orientation unchanged.
        let mid = after + SplashArtModel.flipDuration / 2
        let angle = model.flipAngle(tileIndex: 0, now: mid)
        #expect(angle > 0 && angle < .pi / 2)
        #expect(model.tiles[0].orient == originalOrient)

        // Completion toggles orientation and records lastFlip.
        let done = after + SplashArtModel.flipDuration
        #expect(model.flipAngle(tileIndex: 0, now: done) == 0)
        #expect(model.tiles[0].orient == originalOrient ^ 1)
        #expect(model.tiles[0].flipStart == -1)
        #expect(model.tiles[0].lastFlip == done)

        // Refractory: no re-flip within 350ms of lastFlip.
        model.flipNear(x: tile.cx, y: tile.cy, reach: 100, now: done + 100)
        #expect(model.tiles[0].flipStart == -1)
        model.flipNear(x: tile.cx, y: tile.cy, reach: 100, now: done + 351)
        #expect(model.tiles[0].flipStart == done + 351)
    }

    @Test func scheduledFlipIsInertUntilItsStart() throws {
        var model = SplashArtModel(width: 390, height: 844, seed: 3)
        model.startReveal(at: 1000)
        let after = 1000 + SplashArtModel.introDuration

        // Touch at tile 0's center with a grid-wide reach: tiles at nonzero
        // distance get flipStart staggered into the future
        // (now + distance * 0.45).
        let anchor = model.tiles[0]
        model.flipNear(x: anchor.cx, y: anchor.cy, reach: 10_000, now: after)
        let index = try #require(
            model.tiles.indices.first { model.tiles[$0].flipStart > after })
        let scheduled = model.tiles[index].flipStart
        let orient = model.tiles[index].orient
        let lastFlip = model.tiles[index].lastFlip

        // Before the scheduled start (the progress <= 0 branch), flipAngle
        // returns 0 and must not toggle orient, clear flipStart, or stamp
        // lastFlip.
        #expect(model.flipAngle(tileIndex: index, now: after) == 0)
        #expect(model.tiles[index].flipStart == scheduled)
        #expect(model.tiles[index].orient == orient)
        #expect(model.tiles[index].lastFlip == lastFlip)

        // Once the staggered start arrives, the flip animates normally.
        let angle = model.flipAngle(
            tileIndex: index, now: scheduled + SplashArtModel.flipDuration / 2)
        #expect(angle > 0 && angle < .pi / 2)
        #expect(model.tiles[index].orient == orient)
    }

    @Test func ambientFlipSchedulesAndReschedules() {
        var model = SplashArtModel(width: 390, height: 844, seed: 8)
        model.startReveal(at: 0)
        let due = model.nextAmbientFlip
        // Not due yet: nothing changes.
        model.ambientFlipIfDue(now: due - 1)
        #expect(model.tiles.allSatisfy { $0.flipStart < 0 })
        // Due: some tiles near the random anchor get scheduled, and the next
        // ambient flip lands 1100–2600ms out.
        model.ambientFlipIfDue(now: due)
        #expect(model.tiles.contains { $0.flipStart >= due })
        #expect(model.nextAmbientFlip >= due + 1100)
        #expect(model.nextAmbientFlip <= due + 2600)
    }

    @Test func introProgressClampsAndEases() {
        var model = SplashArtModel(width: 390, height: 844, seed: 4)
        model.startReveal(at: 0)
        #expect(model.introProgress(at: 0, reducedMotion: false)
            == SplashArtModel.initialRevealProgress)
        #expect(model.introProgress(
            at: SplashArtModel.introDuration, reducedMotion: false) == 1)
        #expect(model.introProgress(at: 0, reducedMotion: true) == 1)
    }
}
