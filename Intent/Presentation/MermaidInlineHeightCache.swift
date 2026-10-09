import Foundation

@MainActor
final class MermaidInlineHeightCache {
    static let shared = MermaidInlineHeightCache()
    private static let entryOverhead = 128
    private static let defaultMaximumEntries = 128
    private static let defaultMaximumCost = 262_144

    private let maximumEntries: Int
    private let maximumCost: Int
    private var heights: [Data: CGFloat] = [:]
    private var recency: [Data] = []
    private(set) var totalCost = 0
    var count: Int { heights.count }

    init(maximumEntries: Int = defaultMaximumEntries, maximumCost: Int = defaultMaximumCost) {
        self.maximumEntries = max(0, maximumEntries)
        self.maximumCost = max(0, maximumCost)
    }

    func height(for source: String) -> CGFloat? {
        let key = Data(source.utf8)
        guard let height = heights[key] else { return nil }
        touch(key)
        return height
    }

    func record(_ state: MermaidRenderState, for source: String, expanded: Bool) {
        guard !expanded, let height = state.height, height.isFinite, height > 0 else { return }
        let key = Data(source.utf8)
        guard maximumEntries > 0, key.count <= maximumCost,
              Self.entryOverhead <= maximumCost - key.count else { return }
        let cost = key.count + Self.entryOverhead
        if heights[key] == nil {
            while heights.count >= maximumEntries || totalCost > maximumCost - cost {
                let oldest = recency.removeFirst()
                heights.removeValue(forKey: oldest)
                totalCost -= oldest.count + Self.entryOverhead
            }
            totalCost += cost
        }
        heights[key] = min(max(height, MermaidAppearance.minimumHeight), MermaidAppearance.maximumInlineHeight)
        touch(key)
    }

    private func touch(_ key: Data) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}
