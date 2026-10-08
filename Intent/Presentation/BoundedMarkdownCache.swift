import Foundation

private enum MarkdownCacheLimits {
    static let entryOverhead = 256
}

/// A synchronous LRU with hard entry and accounted-cost limits, including source keys.
/// Oversized values are returned without displacing the reusable working set.
@MainActor
final class BoundedMarkdownCache<Value> {
    // String equality folds canonically equivalent Unicode. Markdown code and URLs
    // must retain their exact spelling, so equality and hashing use all UTF-8 bytes.
    nonisolated private struct CacheKey: Hashable {
        let source: Data
        let version: Int
    }

    private struct Entry {
        let value: Value
        let cost: Int
    }

    let maximumEntries: Int
    let maximumCost: Int
    private var entries: [CacheKey: Entry] = [:]
    private var recency: [CacheKey] = []
    private(set) var totalCost = 0

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    init(maximumEntries: Int, maximumCost: Int) {
        self.maximumEntries = max(0, maximumEntries)
        self.maximumCost = max(0, maximumCost)
    }

    func value(
        for source: String,
        version: Int,
        cost: (Value) -> Int,
        create: () throws -> Value
    ) rethrows -> Value {
        let key = CacheKey(source: Data(source.utf8), version: version)
        if let entry = entries[key] {
            touch(key)
            return entry.value
        }

        // Failures propagate and are never retained as empty successful parses.
        let value = try create()
        let valueCost = cost(value)
        guard maximumEntries > 0,
              key.source.count <= maximumCost,
              MarkdownCacheLimits.entryOverhead <= maximumCost - key.source.count,
              valueCost >= 0,
              valueCost <= maximumCost - key.source.count - MarkdownCacheLimits.entryOverhead else { return value }
        let entryCost = key.source.count + MarkdownCacheLimits.entryOverhead + valueCost
        while entries.count >= maximumEntries || totalCost > maximumCost - entryCost {
            let oldest = recency.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) {
                totalCost -= removed.cost
            }
        }
        entries[key] = Entry(value: value, cost: entryCost)
        recency.append(key)
        totalCost += entryCost
        return value
    }

    private func touch(_ key: CacheKey) {
        // Linear bookkeeping is bounded by the small entry limit, not message count.
        if let index = recency.firstIndex(of: key) {
            let storedKey = recency.remove(at: index)
            recency.append(storedKey)
        }
    }
}
