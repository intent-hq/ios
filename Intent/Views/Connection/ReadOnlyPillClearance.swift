import Observation
import SwiftUI

@MainActor
@Observable
final class ReadOnlyPillClearance {
    private struct Entry {
        let frame: CGRect
        let depth: Int
    }

    private var entries: [UUID: Entry] = [:]
    private var anchorEntry: Entry?

    func report(_ id: UUID, frame: CGRect, depth: Int) {
        entries[id] = Entry(frame: frame, depth: depth)
    }

    func withdraw(_ id: UUID) {
        entries[id] = nil
    }

    func reportAnchor(_ frame: CGRect?, depth: Int) {
        anchorEntry = frame.map { Entry(frame: $0, depth: depth) }
    }

    func anchor(coverage: ComposerCoverage?) -> CGRect? {
        guard let anchorEntry, coverage?.isForemost(depth: anchorEntry.depth) ?? true else { return nil }
        return anchorEntry.frame
    }

    func top(under span: ClosedRange<CGFloat>, windowBottom: CGFloat, coverage: ComposerCoverage?) -> CGFloat? {
        entries.values
            .filter { entry in
                entry.frame.minX < span.upperBound && entry.frame.maxX > span.lowerBound
                    && entry.frame.maxY > windowBottom / 2
                    && coverage?.isForemost(depth: entry.depth) ?? true
            }
            .map(\.frame.minY)
            .min()
    }
}

private struct ReadOnlyPillClearanceReporter: ViewModifier {
    let isActive: Bool
    @Environment(ReadOnlyPillClearance.self) private var clearance: ReadOnlyPillClearance?
    @Environment(\.composerLayerDepth) private var depth
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect?.self) { isActive ? $0.frame(in: .global) : nil } action: { frame in
                if let frame {
                    clearance?.report(id, frame: frame, depth: depth)
                } else {
                    clearance?.withdraw(id)
                }
            }
            .onDisappear { clearance?.withdraw(id) }
    }
}

private struct ReadOnlyPillAnchorReporter: ViewModifier {
    @Environment(ReadOnlyPillClearance.self) private var clearance: ReadOnlyPillClearance?
    @Environment(\.composerLayerDepth) private var depth

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                clearance?.reportAnchor(frame, depth: depth)
            }
            .onDisappear { clearance?.reportAnchor(nil, depth: depth) }
    }
}

extension View {
    func centersReadOnlyPill() -> some View {
        modifier(ReadOnlyPillAnchorReporter())
    }

    func keepsReadOnlyPillAbove(isActive: Bool = true) -> some View {
        modifier(ReadOnlyPillClearanceReporter(isActive: isActive))
    }
}
