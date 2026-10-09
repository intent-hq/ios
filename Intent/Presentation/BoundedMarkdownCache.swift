import Foundation

private enum MarkdownCacheLimits {
    static let entryOverhead = 256
    static let initialTraceSamples = 8
    static let traceSampleStride = 64
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

    private enum TraceOutcome {
        case bypassed
        case failed
        case hit
        case stored
    }

    private struct TraceCounters {
        var accesses = 0
        var hits = 0
        var misses = 0
        var evictions = 0
        var bypasses = 0
        var failures = 0
        var creationSeconds: TimeInterval = 0
    }

    let maximumEntries: Int
    let maximumCost: Int
    private var entries: [CacheKey: Entry] = [:]
    private var recency: [CacheKey] = []
    private(set) var totalCost = 0
    private let traceName: StaticString?
    private var traceCounters = TraceCounters()

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    init(maximumEntries: Int, maximumCost: Int, traceName: StaticString? = nil) {
        self.maximumEntries = max(0, maximumEntries)
        self.maximumCost = max(0, maximumCost)
        self.traceName = traceName
    }

    func value(
        for source: String,
        version: Int,
        cost: (Value) -> Int,
        create: () throws -> Value
    ) rethrows -> Value {
        let tracing = ConversationTrace.enabled && traceName != nil
        let sampled = tracing && (traceCounters.accesses < MarkdownCacheLimits.initialTraceSamples
            || traceCounters.accesses.isMultiple(of: MarkdownCacheLimits.traceSampleStride))
        var outcome = TraceOutcome.failed
        var evictions = 0
        defer {
            if tracing { recordTrace(outcome: outcome, evictions: evictions, sampled: sampled) }
        }
        let key = CacheKey(source: Data(source.utf8), version: version)
        if let entry = entries[key] {
            touch(key)
            outcome = .hit
            return entry.value
        }

        // Failures propagate and are never retained as empty successful parses.
        let value = try createValue(create, tracing: tracing, sampled: sampled, sourceBytes: key.source.count)
        let valueCost = cost(value)
        outcome = .bypassed
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
                if tracing { evictions += 1 }
            }
        }
        entries[key] = Entry(value: value, cost: entryCost)
        recency.append(key)
        totalCost += entryCost
        outcome = .stored
        return value
    }

    private func createValue(
        _ create: () throws -> Value,
        tracing: Bool,
        sampled: Bool,
        sourceBytes: Int
    ) rethrows -> Value {
        guard tracing, let traceName else { return try create() }
        let interval = sampled ? ConversationTrace.begin(traceName, "sourceBytes=\(sourceBytes)") : nil
        let started = ProcessInfo.processInfo.systemUptime
        var succeeded = false
        defer {
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            traceCounters.creationSeconds += elapsed
            ConversationTrace.end(traceName, interval, "succeeded=\(succeeded) elapsedSeconds=\(elapsed)")
        }
        let value = try create()
        succeeded = true
        return value
    }

    private func recordTrace(outcome: TraceOutcome, evictions: Int, sampled: Bool) {
        traceCounters.accesses += 1
        traceCounters.evictions += evictions
        if outcome == .hit { traceCounters.hits += 1 } else { traceCounters.misses += 1 }
        if outcome == .bypassed { traceCounters.bypasses += 1 }
        if outcome == .failed { traceCounters.failures += 1 }
        guard sampled, let traceName else { return }
        ConversationTrace.emit(
            "MarkdownCacheCounters",
            "cache=\(traceName) accesses=\(traceCounters.accesses) hits=\(traceCounters.hits) misses=\(traceCounters.misses) "
                + "evictions=\(traceCounters.evictions) bypasses=\(traceCounters.bypasses) failures=\(traceCounters.failures) "
                + "creationSeconds=\(traceCounters.creationSeconds) entries=\(count) cost=\(totalCost)"
        )
    }

    private func touch(_ key: CacheKey) {
        // Linear bookkeeping is bounded by the small entry limit, not message count.
        if let index = recency.firstIndex(of: key) {
            let storedKey = recency.remove(at: index)
            recency.append(storedKey)
        }
    }
}
