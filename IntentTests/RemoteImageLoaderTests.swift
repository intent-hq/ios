import Foundation
@testable import Intent
import Testing
import UIKit

/// Covers the remote http(s) fetch path: decode, status/size guards,
/// caching, and the session negative cache.
@MainActor
struct RemoteImageLoaderTests {
    private typealias LoadError = RemoteImageLoader.LoadError

    nonisolated private static let url = URL(string: "https://example.com/pic.png")!

    /// A tiny valid PNG rendered at test time.
    nonisolated private static func pngBytes() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        return renderer.pngData { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    nonisolated private static func response(_ status: Int = 200) throws -> URLResponse {
        try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
    }

    /// Lock-guarded fetch counter usable from the `@Sendable` data fetcher.
    nonisolated private final class FetchCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    @Test func fetchDecodesImage() async throws {
        let png = Self.pngBytes()
        let loader = RemoteImageLoader { _ in (png, try Self.response()) }

        let image = try await loader.image(for: Self.url)

        #expect(image.size.width > 0)
    }

    @Test func secondLoadReturnsCachedImage() async throws {
        let png = Self.pngBytes()
        let counter = FetchCounter()
        let loader = RemoteImageLoader { _ in
            counter.increment()
            return (png, try Self.response())
        }

        let first = try await loader.image(for: Self.url)
        let second = try await loader.image(for: Self.url)

        #expect(first === second)
        #expect(counter.count == 1)
    }

    @Test func non2xxStatusThrowsBadStatus() async {
        let loader = RemoteImageLoader { _ in (Data(), try Self.response(404)) }

        await #expect(throws: LoadError.badStatus(404)) {
            _ = try await loader.image(for: Self.url)
        }
    }

    @Test func undecodableBytesThrowNotAnImage() async {
        let loader = RemoteImageLoader { _ in (Data([1, 2, 3]), try Self.response()) }

        await #expect(throws: LoadError.notAnImage) {
            _ = try await loader.image(for: Self.url)
        }
    }

    @Test func oversizedResponseThrowsFileTooLarge() async {
        let big = Data(count: RemoteImageLoader.maxFileBytes + 1)
        let loader = RemoteImageLoader { _ in (big, try Self.response()) }

        await #expect(throws: LoadError.fileTooLarge) {
            _ = try await loader.image(for: Self.url)
        }
    }

    @Test func failedURLIsNegativelyCached() async {
        let counter = FetchCounter()
        let loader = RemoteImageLoader { _ in
            counter.increment()
            return (Data(), try Self.response(500))
        }

        await #expect(throws: LoadError.badStatus(500)) {
            _ = try await loader.image(for: Self.url)
        }
        await #expect(throws: LoadError.previouslyFailed) {
            _ = try await loader.image(for: Self.url)
        }
        #expect(counter.count == 1)
    }

    @Test func transientOfflineURLErrorDoesNotPoisonNegativeCache() async throws {
        let png = Self.pngBytes()
        let counter = FetchCounter()
        let loader = RemoteImageLoader { _ in
            counter.increment()
            if counter.count == 1 {
                throw URLError(.notConnectedToInternet)
            }
            return (png, try Self.response())
        }

        await #expect(throws: URLError.self) {
            _ = try await loader.image(for: Self.url)
        }
        #expect(loader.failedKeys.isEmpty)

        let recovered = try await loader.image(for: Self.url)
        #expect(recovered.size.width > 0)
        #expect(counter.count == 2)
    }
}
