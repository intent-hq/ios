import Foundation
import UIKit

/// Fetches remote http(s) markdown images over URLSession and decodes them
/// through the same downsampling path as workspace-file images. Results are
/// cached per URL so transcript scrolling never refetches, concurrent
/// requests for the same URL share one in-flight fetch, and failed URLs are
/// negatively cached for the session.
@MainActor
final class RemoteImageLoader {
    static let shared = RemoteImageLoader()

    enum LoadError: Error, Equatable {
        case badStatus(Int)
        case fileTooLarge
        case notAnImage
        case previouslyFailed
    }

    /// Fetches a URL's bytes; injectable for tests.
    typealias DataFetcher = @Sendable (URL) async throws -> (Data, URLResponse)

    /// Refuse to decode responses past this size — same bound as
    /// workspace-file images.
    nonisolated static let maxFileBytes = WorkspaceFileImageLoader.maxFileBytes

    private let cache = NSCache<NSString, UIImage>()
    /// Session-lifetime negative cache: URLs whose fetch/decode failed, so a
    /// persistently broken image doesn't refetch on every scroll-into-view.
    /// Intentionally uncapped (ios#264): it grows only with distinct failed
    /// URLs the transcript actually rendered, at ~160 B per entry measured
    /// by `SessionCacheBoundsMeasurementTests`, so even a 10k-URL session
    /// retains ~1.5 MiB — noise next to the decoded-image cost limit.
    private(set) var failedKeys: Set<String> = []
    private var inFlight: [String: Task<UIImage, Error>] = [:]
    private let fetchData: DataFetcher

    init(
        fetchData: @escaping DataFetcher = { url in
            try await RemoteImageLoader.streamCappedBytes(from: url)
        }
    ) {
        self.fetchData = fetchData
        cache.totalCostLimit = WorkspaceFileImageLoader.cacheTotalCostLimit
    }

    /// Cached-or-fetched image for a remote http(s) URL.
    func image(for url: URL) async throws -> UIImage {
        let key = url.absoluteString
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        if failedKeys.contains(key) {
            throw LoadError.previouslyFailed
        }
        if let task = inFlight[key] {
            return try await task.value
        }
        let task = Task<UIImage, Error> { [fetchData, cache] in
            let image = try await Self.fetchAndDecode(fetchData: fetchData, url: url)
            // Cache inside the task so an early-cancelled awaiter (view
            // scrolled away) doesn't lose the completed fetch.
            cache.setObject(
                image, forKey: key as NSString,
                cost: WorkspaceFileImageLoader.decodedCost(of: image))
            return image
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do {
            return try await task.value
        } catch {
            // Remember the failure for the session (skip cancellation — the
            // fetch itself didn't fail) so broken URLs don't refetch forever.
            if !(error is CancellationError) {
                failedKeys.insert(key)
            }
            throw error
        }
    }

    /// Explicitly concurrent so the download and image decode run on the
    /// global executor, keeping large decodes off the UI thread.
    @concurrent
    private nonisolated static func fetchAndDecode(
        fetchData: DataFetcher, url: URL
    ) async throws -> UIImage {
        let (data, response) = try await fetchData(url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LoadError.badStatus(http.statusCode)
        }
        guard data.count <= maxFileBytes else { throw LoadError.fileTooLarge }
        guard let image = WorkspaceFileImageLoader.decodeImage(data) else {
            throw LoadError.notAnImage
        }
        return image
    }

    /// Default fetcher: streams the response body and aborts as soon as it
    /// exceeds `maxFileBytes`, so a hostile or indefinitely streaming server
    /// cannot buffer unbounded data before the size guard runs.
    @concurrent
    private nonisolated static func streamCappedBytes(
        from url: URL
    ) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard response.expectedContentLength <= Int64(maxFileBytes) else {
            throw LoadError.fileTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(Int(max(response.expectedContentLength, 0)), maxFileBytes))
        for try await byte in bytes {
            guard data.count < maxFileBytes else { throw LoadError.fileTooLarge }
            data.append(byte)
        }
        return (data, response)
    }
}
