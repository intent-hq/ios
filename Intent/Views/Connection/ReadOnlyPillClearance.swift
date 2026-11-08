import Observation
import SwiftUI

/// Bottom chrome in one window (composers, search, floating buttons) that the
/// read-only pill floats above instead of covering. Frames are in window
/// coordinates, which the pill's same-size window shares.
@MainActor
@Observable
final class ReadOnlyPillClearance {
    private struct Entry {
        let frame: CGRect
        let depth: Int
    }

    private var entries: [UUID: Entry] = [:]

    func report(_ id: UUID, frame: CGRect, depth: Int) {
        entries[id] = Entry(frame: frame, depth: depth)
    }

    func withdraw(_ id: UUID) {
        entries[id] = nil
    }

    /// The top of the highest chrome under `span` within the window's lower
    /// half, skipping chrome hidden beneath a sheet or cover.
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
            // Measuring nil while inactive makes activation itself report the frame.
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

extension View {
    /// Keeps the read-only pill above this bottom chrome while `isActive`.
    func keepsReadOnlyPillAbove(isActive: Bool = true) -> some View {
        modifier(ReadOnlyPillClearanceReporter(isActive: isActive))
    }
}
