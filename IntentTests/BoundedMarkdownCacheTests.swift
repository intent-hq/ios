import Foundation
import Testing

@testable import Intent

@MainActor
struct BoundedMarkdownCacheTests {
    @Test func unchangedContentReusesValueAndChangesMiss() {
        let cache = BoundedMarkdownCache<Int>(maximumEntries: 8, maximumCost: 4096)
        var calls = 0
        func load(_ source: String, version: Int = 1) -> Int {
            cache.value(
                for: source,
                version: version,
                cost: { _ in 1 },
                create: {
                    calls += 1
                    return calls
                }
            )
        }

        #expect(load("**hello**") == 1)
        #expect(load(["**", "hello", "**"].joined()) == 1)
        #expect(load("**hello!**") == 2)
        #expect(load("**hello**", version: 2) == 3)
        #expect(load("**hello**") == 1)
        #expect(calls == 3)
        #expect(cache.count == 3)
    }

    @Test func canonicallyEquivalentSourcesKeepExactByteIdentity() {
        let composed = "`caf\u{e9}`"
        let decomposed = "`cafe\u{301}`"
        #expect(composed == decomposed)
        #expect(Data(composed.utf8) != Data(decomposed.utf8))
        let cache = BoundedMarkdownCache<Data>(maximumEntries: 2, maximumCost: 4096)
        var calls = 0
        func load(_ source: String) -> Data {
            cache.value(
                for: source,
                version: 1,
                cost: { $0.count },
                create: {
                    calls += 1
                    return Data(source.utf8)
                }
            )
        }

        #expect(load(composed) == Data(composed.utf8))
        #expect(load(decomposed) == Data(decomposed.utf8))
        #expect(load(composed) == Data(composed.utf8))
        #expect(calls == 2)
    }

    @Test func entryLimitEvictsLeastRecentlyUsedValue() {
        let cache = BoundedMarkdownCache<Int>(maximumEntries: 2, maximumCost: 4096)
        var calls = 0
        func load(_ source: String) -> Int {
            cache.value(
                for: source,
                version: 1,
                cost: { _ in 1 },
                create: {
                    calls += 1
                    return calls
                }
            )
        }

        #expect(load("first") == 1)
        #expect(load("second") == 2)
        #expect(load("first") == 1)
        #expect(load("third") == 3)
        #expect(cache.count == 2)
        #expect(load("first") == 1)
        #expect(load("second") == 4)
    }

    @Test func costLimitIncludesKeysAndEvictionRefundsCost() {
        let cache = BoundedMarkdownCache<Int>(maximumEntries: 100, maximumCost: 1024)
        let source = String(repeating: "a", count: 400)
        let payloadCost = 200
        var calls = 0
        func load(_ suffix: String) -> Int {
            cache.value(
                for: source + suffix,
                version: 1,
                cost: { _ in payloadCost },
                create: {
                    calls += 1
                    return calls
                }
            )
        }

        #expect(load("a") == 1)
        let firstCost = cache.totalCost
        #expect(firstCost >= source.utf8.count + payloadCost)
        #expect(load("b") == 2)
        #expect(cache.count == 1)
        #expect(cache.totalCost == firstCost)
        #expect(load("a") == 3)
        #expect(cache.totalCost <= cache.maximumCost)
    }

    @Test func oversizedValuesBypassCacheWithoutEvictingReusableEntries() {
        let cache = BoundedMarkdownCache<String>(maximumEntries: 2, maximumCost: 1024)
        var calls = 0
        func load(_ source: String, value: String) -> String {
            cache.value(
                for: source,
                version: 1,
                cost: { $0.utf8.count },
                create: {
                    calls += 1
                    return value
                }
            )
        }
        #expect(load("small", value: "kept") == "kept")
        let cost = cache.totalCost
        let large = String(repeating: "x", count: 2048)
        #expect(load("large value", value: large) == large)
        #expect(load(large, value: "large key") == "large key")
        #expect(load("large value", value: large) == large)
        #expect(load("small", value: "unexpected miss") == "kept")
        #expect(calls == 4)
        #expect(cache.count == 1)
        #expect(cache.totalCost == cost)
    }

    @Test func streamingRevisionsRemainBounded() {
        let cache = BoundedMarkdownCache<Int>(maximumEntries: 4, maximumCost: 2048)
        for revision in 1...100 {
            let source = String(repeating: "x", count: revision)
            let value = cache.value(
                for: source,
                version: 1,
                cost: { _ in source.utf8.count },
                create: { revision }
            )
            #expect(value == revision)
            #expect(cache.count <= cache.maximumEntries)
            #expect(cache.totalCost <= cache.maximumCost)
        }
    }

    @Test func failedLoadsAreRethrownAndRetried() throws {
        let cache = BoundedMarkdownCache<String>(maximumEntries: 2, maximumCost: 1024)
        var calls = 0
        func load() throws -> String {
            try cache.value(
                for: "source",
                version: 1,
                cost: { $0.utf8.count },
                create: {
                    calls += 1
                    if calls == 1 { throw ParseFailure.expected }
                    return "recovered"
                }
            )
        }
        #expect(throws: ParseFailure.self) { try load() }
        #expect(cache.isEmpty)
        #expect(cache.totalCost == 0)
        #expect(try load() == "recovered")
        #expect(try load() == "recovered")
        #expect(calls == 2)
    }

    @Test func disabledCacheStillReturnsFreshValues() {
        let cache = BoundedMarkdownCache<Int>(maximumEntries: 0, maximumCost: 0)
        #expect(cache.value(for: "source", version: 1, cost: { _ in 0 }, create: { 1 }) == 1)
        #expect(cache.value(for: "source", version: 1, cost: { _ in 0 }, create: { 2 }) == 2)
        #expect(cache.isEmpty)
        #expect(cache.totalCost == 0)
    }

    private enum ParseFailure: Error {
        case expected
    }
}
