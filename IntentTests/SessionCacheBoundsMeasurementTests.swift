import Combine
import Foundation
@testable import Intent
import Testing
import UIKit

/// ios#264 measurement harness for the three session-lifetime caches with no
/// count bound: `WorkspaceFileImageLoader.failedKeys`,
/// `RemoteImageLoader.failedKeys` and `AttachmentImageLoader.pathCache`.
///
/// Each cache is driven through a scripted long session of distinct keys
/// shaped like production ids/paths/URLs. Entry counts are sampled at
/// checkpoints so the growth curve is visible, and retained bytes are
/// estimated from each collection's observed table capacity plus Swift
/// native string storage
/// (malloc-level `mstats` deltas print alongside as an informational
/// cross-check — process-wide, so concurrent suites add noise). Rows print
/// with an `[ios#264]` prefix for the issue/PR table; the assertions pin the
/// measured contract: linear growth (no eviction) at a few hundred bytes per
/// entry, immaterial at realistic cardinality. Adding a bound later must
/// update the growth expectations here.
@Suite(.serialized)
@MainActor
struct SessionCacheBoundsMeasurementTests {
    /// A scripted session: `workspaces` distinct workspaces, each rendering
    /// `keysPerWorkspace` distinct image references that all populate the
    /// cache (every link broken, or every image an attachment reference).
    private struct SessionProfile {
        let name: String
        let workspaces: Int
        let keysPerWorkspace: Int
        var totalKeys: Int {
            workspaces * keysPerWorkspace
        }
    }

    /// A long day across many workspaces where every rendered image
    /// populates the cache — already a worst case for the negative caches.
    private static let realistic = SessionProfile(name: "realistic", workspaces: 25, keysPerWorkspace: 40)
    /// Ten times the realistic session, to expose the growth slope.
    private static let stress = SessionProfile(name: "stress", workspaces: 100, keysPerWorkspace: 100)

    /// Ceiling on the per-entry estimate: a regression that starts retaining
    /// heavier values (decoded images, errors, responses) trips this.
    private static let maxBytesPerEntry = 512
    /// Materiality threshold for the realistic session, per cache.
    private static let realisticRetainedCeiling = 1 << 20

    /// Routing stub that records nothing, so retained bytes reflect the
    /// loader caches alone. `file.getAttachmentInfo` resolves each attachment
    /// to a distinct path; every other request fails like a missing file.
    @MainActor
    private final class ScriptedConnection: ConnectionManagerRouting {
        var connectionState: ConnectionState = .connected
        var connectionStatePublisher: AnyPublisher<ConnectionState, Never> {
            Just(.connected).eraseToAnyPublisher()
        }

        var requestCount = 0

        func retryConnection() {}

        func request(_ method: String, params: [String: Any], timeout _: TimeInterval) async throws -> Any {
            requestCount += 1
            guard method == "file.getAttachmentInfo" else {
                throw NSError(
                    domain: "WebSocket",
                    code: -32_602,
                    userInfo: [NSError.intentErrorDataCodeKey: "not-found"]
                )
            }
            let attachmentId = params["attachmentId"] as? String ?? ""
            return [
                "attachmentId": attachmentId,
                "fileName": "screenshot.png",
                "size": 1,
                "uploadedAt": "2026-01-01T00:00:00Z",
                "exists": true,
                "path": SessionCacheBoundsMeasurementTests.attachmentPath(attachmentId)
            ]
        }

        @discardableResult
        func onEvent(_: (String, Any) -> Void) -> UUID {
            UUID()
        }

        func removeEventHandler(id _: UUID) {}
        func registerSubscriptionHandler(id _: String, handler _: @MainActor (SubscriptionPush) -> Void) {}
        func unregisterSubscriptionHandler(id _: String) {}
    }

    // MARK: - Key shapes (deterministic, production-length)

    /// A 36-character UUID-shaped id derived from two indices.
    nonisolated private static func syntheticId(_ high: Int, _ low: Int) -> String {
        String(format: "%08X-0000-4000-8000-%012X", high, low)
    }

    nonisolated private static func workspaceId(_ workspace: Int) -> String {
        syntheticId(0xA0, workspace)
    }

    /// Broken `intent://local/file/...` link target, workspace-relative.
    nonisolated private static func filePath(_ workspace: Int, _ index: Int) -> String {
        "docs/screenshots/\(syntheticId(workspace, index)).png"
    }

    /// GitHub user-attachment URL, the common remote image shape.
    nonisolated private static func remoteURL(_ workspace: Int, _ index: Int) -> URL {
        guard let url = URL(string: "https://github.com/user-attachments/assets/\(syntheticId(workspace, index))") else {
            fatalError("Could not create synthetic attachment URL")
        }
        return url
    }

    nonisolated private static func attachmentId(_ workspace: Int, _ index: Int) -> String {
        syntheticId(0xB0 + workspace, index)
    }

    /// Registry-row path under `.intent/attachments/`.
    nonisolated private static func attachmentPath(_ attachmentId: String) -> String {
        ".intent/attachments/\(attachmentId)-screenshot.png"
    }

    nonisolated private static func response(_ status: Int, for url: URL) -> URLResponse {
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
            fatalError("Could not create synthetic response")
        }
        return response
    }

    // MARK: - Retained-bytes model

    /// Swift native string storage: up to 15 UTF-8 bytes live inline in the
    /// 16-byte `String`; longer strings own a heap object (32-byte header +
    /// bytes + NUL) rounded up to malloc's 16-byte quantum.
    nonisolated private static func heapBytes(of string: String) -> Int {
        let count = string.utf8.count
        return count <= 15 ? 0 : (32 + count + 1 + 15) / 16 * 16
    }

    /// Native hash tables keep a power-of-two bucket count and advertise
    /// `capacity` as the ≤ 3/4-load fill of that table, so the table the
    /// collection actually allocated (including any over-reservation) is
    /// recovered from its observed `capacity`, never inferred from `count`.
    nonisolated private static func bucketCount(forCapacity capacity: Int) -> Int {
        var buckets = 1
        while buckets * 3 / 4 < capacity {
            buckets *= 2
        }
        return buckets
    }

    /// Storage header + one 16-byte slot per bucket + 1-bit occupancy map +
    /// heap storage of every key.
    nonisolated private static func retainedBytes(of set: Set<String>) -> Int {
        let buckets = bucketCount(forCapacity: set.capacity)
        return 64 + buckets * MemoryLayout<String>.stride + buckets / 8
            + set.reduce(0) { $0 + heapBytes(of: $1) }
    }

    /// As `retainedBytes(of: Set)` with a second 16-byte slot per bucket for
    /// values and their heap storage.
    nonisolated private static func retainedBytes(of dictionary: [String: String]) -> Int {
        let buckets = bucketCount(forCapacity: dictionary.capacity)
        return 64 + buckets * 2 * MemoryLayout<String>.stride + buckets / 8
            + dictionary.reduce(0) { $0 + heapBytes(of: $1.key) + heapBytes(of: $1.value) }
    }

    nonisolated private static func mallocBytesUsed() -> Int {
        Int(mstats().bytes_used)
    }

    nonisolated private static func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1 << 20 {
            return String(format: "%.2f MiB", Double(bytes) / Double(1 << 20))
        }
        if bytes >= 1 << 10 {
            return String(format: "%.1f KiB", Double(bytes) / Double(1 << 10))
        }
        return "\(bytes) B"
    }

    // MARK: - Session driver

    private struct Measurement {
        let cache: String
        let profile: SessionProfile
        /// Entry count after each quarter of the session.
        var checkpoints: [(driven: Int, entries: Int)] = []
        var retainedBytes = 0
        /// Process-wide malloc growth across the run — informational only.
        var mallocDelta = 0

        var entries: Int {
            checkpoints.last?.entries ?? 0
        }

        var bytesPerEntry: Int {
            entries == 0 ? 0 : retainedBytes / entries
        }

        var markdownRow: String {
            let curve = checkpoints.map { "\($0.entries)/\($0.driven)" }.joined(separator: " → ")
            let retained = SessionCacheBoundsMeasurementTests.formatBytes(retainedBytes)
            let malloc = SessionCacheBoundsMeasurementTests.formatBytes(mallocDelta)
            return "| `\(cache)` | \(profile.name) (\(profile.workspaces) ws × \(profile.keysPerWorkspace)) "
                + "| \(curve) | \(retained) | \(bytesPerEntry) B | \(malloc) |"
        }
    }

    /// Drives `populate(workspace, index)` over the whole profile, sampling
    /// `entries()` after each quarter and `retained()` once at the end.
    private static func run(
        cache: String,
        profile: SessionProfile,
        populate: (Int, Int) async -> Void,
        entries: () -> Int,
        retained: () -> Int
    ) async -> Measurement {
        var measurement = Measurement(cache: cache, profile: profile)
        let mallocBefore = mallocBytesUsed()
        let quarter = max(1, profile.workspaces / 4)
        var driven = 0
        for workspace in 0 ..< profile.workspaces {
            for index in 0 ..< profile.keysPerWorkspace {
                await populate(workspace, index)
                driven += 1
            }
            if (workspace + 1).isMultiple(of: quarter) || workspace + 1 == profile.workspaces {
                measurement.checkpoints.append((driven, entries()))
            }
        }
        measurement.mallocDelta = max(0, mallocBytesUsed() - mallocBefore)
        measurement.retainedBytes = retained()
        print("[ios#264] \(measurement.markdownRow)")
        return measurement
    }

    /// The measured contract: no eviction (entries track distinct keys
    /// exactly), a few hundred bytes per entry, and an immaterial footprint
    /// for the realistic session.
    private static func expectMeasuredContract(
        _ measurement: Measurement,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let label = "\(measurement.cache) [\(measurement.profile.name)]"
        for checkpoint in measurement.checkpoints {
            #expect(
                checkpoint.entries == checkpoint.driven,
                "\(label): \(checkpoint.entries) entries after \(checkpoint.driven) distinct keys",
                sourceLocation: sourceLocation
            )
        }
        #expect(
            measurement.bytesPerEntry <= maxBytesPerEntry,
            "\(label): \(measurement.bytesPerEntry) B/entry",
            sourceLocation: sourceLocation
        )
        if measurement.profile.name == realistic.name {
            #expect(
                measurement.retainedBytes < realisticRetainedCeiling,
                "\(label): retains \(formatBytes(measurement.retainedBytes))",
                sourceLocation: sourceLocation
            )
        }
    }

    // MARK: - Estimator sensitivity

    /// The estimate must follow the allocated table, not the entry count:
    /// a cache that starts over-reserving (e.g. `reserveCapacity(n * n)`)
    /// with the same keys has to breach the per-entry ceiling and the
    /// realistic footprint ceiling, or the guards above are inert.
    @Test func overReservedCollectionsBreachFootprintGuards() {
        let keys = (0 ..< Self.realistic.workspaces).flatMap { workspace in
            (0 ..< Self.realistic.keysPerWorkspace).map { Self.filePath(workspace, $0) }
        }
        let superlinear = keys.count * keys.count

        let set = Set(keys)
        var overReservedSet = set
        overReservedSet.reserveCapacity(superlinear)
        #expect(overReservedSet.count == set.count)
        #expect(Self.retainedBytes(of: set) / set.count <= Self.maxBytesPerEntry)
        #expect(Self.retainedBytes(of: set) < Self.realisticRetainedCeiling)
        #expect(Self.retainedBytes(of: overReservedSet) / set.count > Self.maxBytesPerEntry)
        #expect(Self.retainedBytes(of: overReservedSet) >= Self.realisticRetainedCeiling)

        let dictionary = Dictionary(uniqueKeysWithValues: keys.map { ($0, Self.attachmentPath($0)) })
        var overReservedDictionary = dictionary
        overReservedDictionary.reserveCapacity(superlinear)
        #expect(overReservedDictionary.count == dictionary.count)
        #expect(Self.retainedBytes(of: dictionary) / dictionary.count <= Self.maxBytesPerEntry)
        #expect(Self.retainedBytes(of: dictionary) < Self.realisticRetainedCeiling)
        #expect(Self.retainedBytes(of: overReservedDictionary) / dictionary.count > Self.maxBytesPerEntry)
        #expect(Self.retainedBytes(of: overReservedDictionary) >= Self.realisticRetainedCeiling)
    }

    // MARK: - Per-cache scripted sessions

    @Test func workspaceFileNegativeCacheGrowthAndFootprint() async {
        for profile in [Self.realistic, Self.stress] {
            let loader = WorkspaceFileImageLoader(connection: ScriptedConnection())
            let measurement = await Self.run(
                cache: "WorkspaceFileImageLoader.failedKeys",
                profile: profile,
                populate: { workspace, index in
                    _ = try? await loader.image(
                        workspaceId: Self.workspaceId(workspace),
                        path: Self.filePath(workspace, index)
                    )
                },
                entries: { loader.failedKeys.count },
                retained: { Self.retainedBytes(of: loader.failedKeys) }
            )
            Self.expectMeasuredContract(measurement)
        }
    }

    @Test func remoteNegativeCacheGrowthAndFootprint() async {
        for profile in [Self.realistic, Self.stress] {
            let loader = RemoteImageLoader { url in (Data(), Self.response(404, for: url)) }
            let measurement = await Self.run(
                cache: "RemoteImageLoader.failedKeys",
                profile: profile,
                populate: { workspace, index in
                    _ = try? await loader.image(for: Self.remoteURL(workspace, index))
                },
                entries: { loader.failedKeys.count },
                retained: { Self.retainedBytes(of: loader.failedKeys) }
            )
            Self.expectMeasuredContract(measurement)
        }
    }

    @Test func attachmentPathCacheGrowthAndFootprint() async {
        for profile in [Self.realistic, Self.stress] {
            let connection = ScriptedConnection()
            let loader = AttachmentImageLoader(
                connection: connection,
                fileLoader: WorkspaceFileImageLoader(connection: connection)
            )
            let measurement = await Self.run(
                cache: "AttachmentImageLoader.pathCache",
                profile: profile,
                populate: { workspace, index in
                    _ = try? await loader.image(
                        workspaceId: Self.workspaceId(workspace),
                        attachmentId: Self.attachmentId(workspace, index)
                    )
                },
                entries: { loader.pathCache.count },
                retained: { Self.retainedBytes(of: loader.pathCache) }
            )
            Self.expectMeasuredContract(measurement)
            // Immutable rows: one resolution plus one (failing) byte fetch per
            // attachment, never a second `file.getAttachmentInfo`. The malloc
            // delta for this row also carries the companion file loader's
            // negative cache.
            #expect(connection.requestCount == 2 * profile.totalKeys)
        }
    }
}
