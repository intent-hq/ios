import Combine
import Foundation
import Testing
import UIKit
@testable import Intent

/// ios#264 measurement harness for the three session-lifetime caches with no
/// count bound: `WorkspaceFileImageLoader.failedKeys`,
/// `RemoteImageLoader.failedKeys` and `AttachmentImageLoader.pathCache`.
///
/// Each cache is driven through a scripted long session of distinct keys
/// shaped like production ids/paths/URLs. Entry counts are sampled at
/// checkpoints so the growth curve is visible, and retained bytes are
/// estimated from the hash-table geometry plus Swift native string storage
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
        var totalKeys: Int { workspaces * keysPerWorkspace }
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

        func request(_ method: String, params: [String: Any], timeout: TimeInterval) async throws -> Any {
            requestCount += 1
            guard method == "file.getAttachmentInfo" else {
                throw NSError(
                    domain: "WebSocket", code: -32602,
                    userInfo: [NSError.intentErrorDataCodeKey: "not-found"])
            }
            let attachmentId = params["attachmentId"] as? String ?? ""
            return [
                "attachmentId": attachmentId, "fileName": "screenshot.png", "size": 1,
                "uploadedAt": "2026-01-01T00:00:00Z", "exists": true,
                "path": SessionCacheBoundsMeasurementTests.attachmentPath(attachmentId),
            ]
        }

        @discardableResult
        func onEvent(_ handler: @escaping (String, Any) -> Void) -> UUID { UUID() }
        func removeEventHandler(id: UUID) {}
        func registerSubscriptionHandler(id: String, handler: @escaping @MainActor (SubscriptionPush) -> Void) {}
        func unregisterSubscriptionHandler(id: String) {}
    }

    // MARK: - Key shapes (deterministic, production-length)

    /// A 36-character UUID-shaped id derived from two indices.
    private nonisolated static func syntheticId(_ hi: Int, _ lo: Int) -> String {
        String(format: "%08X-0000-4000-8000-%012X", hi, lo)
    }

    private nonisolated static func workspaceId(_ w: Int) -> String { syntheticId(0xA0, w) }

    /// Broken `intent://local/file/...` link target, workspace-relative.
    private nonisolated static func filePath(_ w: Int, _ i: Int) -> String {
        "docs/screenshots/\(syntheticId(w, i)).png"
    }

    /// GitHub user-attachment URL, the common remote image shape.
    private nonisolated static func remoteURL(_ w: Int, _ i: Int) -> URL {
        URL(string: "https://github.com/user-attachments/assets/\(syntheticId(w, i))")!
    }

    private nonisolated static func attachmentId(_ w: Int, _ i: Int) -> String { syntheticId(0xB0 + w, i) }

    /// Registry-row path under `.intent/attachments/`.
    private nonisolated static func attachmentPath(_ attachmentId: String) -> String {
        ".intent/attachments/\(attachmentId)-screenshot.png"
    }

    private nonisolated static func response(_ status: Int, for url: URL) -> URLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    // MARK: - Retained-bytes model

    /// Swift native string storage: up to 15 UTF-8 bytes live inline in the
    /// 16-byte `String`; longer strings own a heap object (32-byte header +
    /// bytes + NUL) rounded up to malloc's 16-byte quantum.
    private nonisolated static func heapBytes(of string: String) -> Int {
        let count = string.utf8.count
        return count <= 15 ? 0 : (32 + count + 1 + 15) / 16 * 16
    }

    /// Native hash tables keep a power-of-two bucket count at ≤ 3/4 load.
    private nonisolated static func bucketCount(forCount count: Int) -> Int {
        var buckets = 1
        while buckets * 3 / 4 < count { buckets *= 2 }
        return buckets
    }

    /// Storage header + one 16-byte slot per bucket + 1-bit occupancy map +
    /// heap storage of every key.
    private nonisolated static func retainedBytes(of set: Set<String>) -> Int {
        let buckets = bucketCount(forCount: set.count)
        return 64 + buckets * MemoryLayout<String>.stride + buckets / 8
            + set.reduce(0) { $0 + heapBytes(of: $1) }
    }

    /// As `retainedBytes(of: Set)` with a second 16-byte slot per bucket for
    /// values and their heap storage.
    private nonisolated static func retainedBytes(of dictionary: [String: String]) -> Int {
        let buckets = bucketCount(forCount: dictionary.count)
        return 64 + buckets * 2 * MemoryLayout<String>.stride + buckets / 8
            + dictionary.reduce(0) { $0 + heapBytes(of: $1.key) + heapBytes(of: $1.value) }
    }

    private nonisolated static func mallocBytesUsed() -> Int { Int(mstats().bytes_used) }

    private nonisolated static func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1 << 20 { return String(format: "%.2f MiB", Double(bytes) / Double(1 << 20)) }
        if bytes >= 1 << 10 { return String(format: "%.1f KiB", Double(bytes) / Double(1 << 10)) }
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

        var entries: Int { checkpoints.last?.entries ?? 0 }
        var bytesPerEntry: Int { entries == 0 ? 0 : retainedBytes / entries }

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
        cache: String, profile: SessionProfile,
        populate: (Int, Int) async -> Void,
        entries: () -> Int,
        retained: () -> Int
    ) async -> Measurement {
        var measurement = Measurement(cache: cache, profile: profile)
        let mallocBefore = mallocBytesUsed()
        let quarter = max(1, profile.workspaces / 4)
        var driven = 0
        for workspace in 0..<profile.workspaces {
            for index in 0..<profile.keysPerWorkspace {
                await populate(workspace, index)
                driven += 1
            }
            if (workspace + 1) % quarter == 0 || workspace + 1 == profile.workspaces {
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
        _ measurement: Measurement, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let label = "\(measurement.cache) [\(measurement.profile.name)]"
        for checkpoint in measurement.checkpoints {
            #expect(
                checkpoint.entries == checkpoint.driven,
                "\(label): \(checkpoint.entries) entries after \(checkpoint.driven) distinct keys",
                sourceLocation: sourceLocation)
        }
        #expect(
            measurement.bytesPerEntry <= maxBytesPerEntry,
            "\(label): \(measurement.bytesPerEntry) B/entry", sourceLocation: sourceLocation)
        if measurement.profile.name == realistic.name {
            #expect(
                measurement.retainedBytes < realisticRetainedCeiling,
                "\(label): retains \(formatBytes(measurement.retainedBytes))", sourceLocation: sourceLocation)
        }
    }

    // MARK: - Per-cache scripted sessions

    @Test func workspaceFileNegativeCacheGrowthAndFootprint() async {
        for profile in [Self.realistic, Self.stress] {
            let loader = WorkspaceFileImageLoader(connection: ScriptedConnection())
            let measurement = await Self.run(
                cache: "WorkspaceFileImageLoader.failedKeys", profile: profile,
                populate: { workspace, index in
                    _ = try? await loader.image(
                        workspaceId: Self.workspaceId(workspace), path: Self.filePath(workspace, index))
                },
                entries: { loader.failedKeys.count },
                retained: { Self.retainedBytes(of: loader.failedKeys) })
            Self.expectMeasuredContract(measurement)
        }
    }

    @Test func remoteNegativeCacheGrowthAndFootprint() async {
        for profile in [Self.realistic, Self.stress] {
            let loader = RemoteImageLoader(fetchData: { url in (Data(), Self.response(404, for: url)) })
            let measurement = await Self.run(
                cache: "RemoteImageLoader.failedKeys", profile: profile,
                populate: { workspace, index in
                    _ = try? await loader.image(for: Self.remoteURL(workspace, index))
                },
                entries: { loader.failedKeys.count },
                retained: { Self.retainedBytes(of: loader.failedKeys) })
            Self.expectMeasuredContract(measurement)
        }
    }

    @Test func attachmentPathCacheGrowthAndFootprint() async {
        for profile in [Self.realistic, Self.stress] {
            let connection = ScriptedConnection()
            let loader = AttachmentImageLoader(
                connection: connection, fileLoader: WorkspaceFileImageLoader(connection: connection))
            let measurement = await Self.run(
                cache: "AttachmentImageLoader.pathCache", profile: profile,
                populate: { workspace, index in
                    _ = try? await loader.image(
                        workspaceId: Self.workspaceId(workspace),
                        attachmentId: Self.attachmentId(workspace, index))
                },
                entries: { loader.pathCache.count },
                retained: { Self.retainedBytes(of: loader.pathCache) })
            Self.expectMeasuredContract(measurement)
            // Immutable rows: one resolution plus one (failing) byte fetch per
            // attachment, never a second `file.getAttachmentInfo`. The malloc
            // delta for this row also carries the companion file loader's
            // negative cache.
            #expect(connection.requestCount == 2 * profile.totalKeys)
        }
    }
}
