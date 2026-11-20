import Foundation
import UIKit

@MainActor
final class RemoteImageLoader {
    static let shared = RemoteImageLoader()

    enum LoadError: Error, Equatable {
        case badStatus(Int)
        case fileTooLarge
        case notAnImage
        case previouslyFailed
    }

    typealias DataFetcher = @Sendable (URL) async throws -> (Data, URLResponse)

    nonisolated static let maxFileBytes = WorkspaceFileImageLoader.maxFileBytes

    // swiftlint:disable:next legacy_objc_type
    private let cache = NSCache<NSString, UIImage>()
    private(set) var failedKeys: Set<String> = []
    private var inFlight: [String: Task<UIImage, Error>] = [:]
    private let fetchData: DataFetcher
    nonisolated private static let successfulHTTPStatusCodes: ClosedRange<Int> = 200...299

    init(
        fetchData: @escaping DataFetcher = { url in
            try await RemoteImageLoader.streamCappedBytes(from: url)
        }
    ) {
        self.fetchData = fetchData
        cache.totalCostLimit = WorkspaceFileImageLoader.cacheTotalCostLimit
    }

    func image(for url: URL) async throws -> UIImage {
        let key = url.absoluteString
        // swiftlint:disable:next legacy_objc_type
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
            cache.setObject(
                image,
                // swiftlint:disable:next legacy_objc_type
                forKey: key as NSString,
                cost: WorkspaceFileImageLoader.decodedCost(of: image)
            )
            return image
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do {
            return try await task.value
        } catch {
            if Self.shouldNegativelyCache(error) {
                failedKeys.insert(key)
            }
            throw error
        }
    }

    func forgetFailure(for url: URL) {
        failedKeys.remove(url.absoluteString)
    }

    nonisolated static func shouldNegativelyCache(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError, urlError.isTransientConnectivityError {
            return false
        }
        return true
    }

    @concurrent
    nonisolated private static func fetchAndDecode(
        fetchData: DataFetcher,
        url: URL
    ) async throws -> UIImage {
        let (data, response) = try await fetchData(url)
        if let http = response as? HTTPURLResponse,
           !Self.successfulHTTPStatusCodes.contains(http.statusCode) {
            throw LoadError.badStatus(http.statusCode)
        }
        guard data.count <= maxFileBytes else { throw LoadError.fileTooLarge }
        guard let image = WorkspaceFileImageLoader.decodeImage(data) else {
            throw LoadError.notAnImage
        }
        return image
    }

    @concurrent
    nonisolated private static func streamCappedBytes(
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

extension URLError {
    nonisolated var isTransientConnectivityError: Bool {
        switch code {
        case .cancelled,
             .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed:
            return true
        default:
            return false
        }
    }
}
