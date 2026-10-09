import Foundation
@testable import Intent
import Observation
import SwiftUI
import Testing
import UIKit

@MainActor
struct MermaidInlineHeightCacheTests {
    @Test func keepsSuccessfulInlineHeightThroughLoadingAndFailure() {
        let cache = MermaidInlineHeightCache()
        cache.record(.rendered(900), for: "diagram", expanded: false)
        cache.record(.loading, for: "diagram", expanded: false)
        cache.record(.failed("Retry"), for: "diagram", expanded: false)
        #expect(cache.height(for: "diagram") == 360)
        cache.record(.rendered(144), for: "diagram", expanded: false)
        #expect(cache.height(for: "diagram") == 144)
        cache.record(.rendered(20), for: "diagram", expanded: false)
        #expect(cache.height(for: "diagram") == 100)
    }

    @Test func rejectsFullscreenAndInvalidMeasurements() {
        let cache = MermaidInlineHeightCache()
        cache.record(.rendered(144), for: "diagram", expanded: false)
        for height in [CGFloat.infinity, .nan, 0, -1] {
            cache.record(.rendered(height), for: "diagram", expanded: false)
        }
        cache.record(.rendered(800), for: "diagram", expanded: true)
        cache.record(.rendered(800), for: "fullscreen-only", expanded: true)
        #expect(cache.height(for: "diagram") == 144)
        #expect(cache.height(for: "fullscreen-only") == nil)
        #expect(cache.height(for: "changed source") == nil)
    }

    @Test func boundsEntriesAndSourceBytesWithoutLosingRecentHeights() {
        let cache = MermaidInlineHeightCache(maximumEntries: 2, maximumCost: 300)
        cache.record(.rendered(144), for: "first", expanded: false)
        cache.record(.rendered(160), for: "second", expanded: false)
        #expect(cache.height(for: "first") == 144)
        cache.record(.rendered(180), for: "third", expanded: false)
        #expect(cache.height(for: "second") == nil)
        cache.record(.rendered(200), for: String(repeating: "x", count: 301), expanded: false)
        #expect(cache.count == 2)
        #expect(cache.totalCost <= 300)
        #expect(cache.height(for: "first") == 144)
        cache.record(.rendered(120), for: "first", expanded: false)
        #expect(cache.count == 2)
        #expect(cache.height(for: "first") == 120)
    }
}

@MainActor
@Suite(.serialized)
struct MermaidInlineHeightHostingTests {
    private static let viewport = CGRect(x: 0, y: 0, width: 390, height: 800)
    private static let tolerance: CGFloat = 1
    private static let loadingObservation: Duration = .milliseconds(200)

    @Test(arguments: [CGFloat(144), CGFloat(360)], [1, 3])
    func reconstructedCanvasesKeepHeightHints(height: CGFloat, diagrams: Int) async throws {
        let source = "flowchart TB\n A[\(UUID().uuidString)] --> B[Load] --> C[Render] --> D[Display] --> E[Done]"
        MermaidInlineHeightCache.shared.record(.rendered(height), for: source, expanded: false)
        let state = ProbeState()
        let controller = UIHostingController(rootView: Probe(source: source, count: diagrams, state: state))
        let window = UIWindow(frame: Self.viewport)
        controller.view.frame = window.bounds
        controller.beginAppearanceTransition(true, animated: false)
        window.addSubview(controller.view)
        window.isHidden = false
        controller.endAppearanceTransition()
        defer {
            controller.beginAppearanceTransition(false, animated: false)
            controller.view.removeFromSuperview()
            window.isHidden = true
            controller.endAppearanceTransition()
        }

        for generation in 0..<3 {
            state.samples.removeAll()
            state.generation = generation
            state.dark.toggle()
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: Self.loadingObservation)
            let minimum = try #require(state.samples.filter { $0 > 0 }.min())
            let expected = (height + Constants.Accessibility.minimumTapTarget) * CGFloat(diagrams)
            #expect(minimum + Self.tolerance >= expected)
        }
    }

    @Observable
    final class ProbeState {
        var generation = 0
        var dark = false
        @ObservationIgnored var samples: [CGFloat] = []
    }

    private struct Probe: View {
        let source: String
        let count: Int
        let state: ProbeState

        var body: some View {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { _ in
                        MermaidDiagramView(source: source)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    state.samples.append(height)
                }
                .id(state.generation)
            }
            .environment(\.colorScheme, state.dark ? .dark : .light)
        }
    }
}
