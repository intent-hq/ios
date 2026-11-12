import Foundation
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// Which subresources an HTML report may load, and from where. Pure rules,
/// kept apart from WebKit so path resolution and limits are unit-testable.
nonisolated enum HTMLFileResourcePolicy {
    /// Private scheme for the report's base URL; WebKit never handles it itself.
    static let scheme = "intent-file"
    /// Every workspace path sits under this first path segment, so a relative
    /// URL that climbs above the workspace root (or an absolute `/x.png`) no
    /// longer starts with it and is rejected.
    static let rootSegment = "workspace"
    // Report screenshots are well under these; they bound transfer and memory.
    // swiftlint:disable no_magic_numbers
    static let maxResourceBytes = 4 * 1024 * 1024
    static let maxPageBytes = 16 * 1024 * 1024
    // swiftlint:enable no_magic_numbers
    static let maxPageRequests = 64

    /// Images, stylesheets and web fonts only: no scripts, frames, media or documents.
    enum Kind: Equatable {
        case font(mimeType: String)
        case image(mimeType: String)
        case stylesheet

        var mimeType: String {
            switch self {
            case .font(let mimeType), .image(let mimeType): mimeType
            case .stylesheet: "text/css"
            }
        }
    }

    enum Rejection: Error, Equatable {
        case invalidContent
        case outsideWorkspace
        case pageBudgetExhausted
        case tooLarge
        case unsupportedType
        case wrongOrigin
    }

    struct Resource: Equatable {
        let path: String
        let kind: Kind
    }

    private static let kinds: [String: Kind] = [
        "png": .image(mimeType: "image/png"),
        "jpg": .image(mimeType: "image/jpeg"),
        "jpeg": .image(mimeType: "image/jpeg"),
        "gif": .image(mimeType: "image/gif"),
        "webp": .image(mimeType: "image/webp"),
        "css": .stylesheet,
        "woff2": .font(mimeType: "font/woff2"),
        "woff": .font(mimeType: "font/woff"),
        "ttf": .font(mimeType: "font/ttf"),
        "otf": .font(mimeType: "font/otf")
    ]

    /// Leading signature for each font MIME type (TrueType has two).
    private static let fontSignatures: [String: [[UInt8]]] = [
        "font/woff2": [Array("wOF2".utf8)],
        "font/woff": [Array("wOFF".utf8)],
        "font/ttf": [[0x00, 0x01, 0x00, 0x00], Array("true".utf8)],
        "font/otf": [Array("OTTO".utf8)]
    ]

    private static let imageTypes: Set<String> = [
        UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier, UTType.webP.identifier
    ]

    /// The base URL for a report at a workspace-relative `filePath`, on a
    /// per-page `host` so another page's URLs never resolve here.
    static func baseURL(host: String, filePath: String) -> URL? {
        let parts = filePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let segments = try? workspaceSegments(parts, allowsCurrentDirectory: true), !segments.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + ([rootSegment] + segments).joined(separator: "/")
        return components.url
    }

    /// The workspace path and type a resolved subresource URL may load.
    static func resource(for url: URL, host: String) throws(Rejection) -> Resource {
        guard url.scheme?.lowercased() == scheme, url.host()?.lowercased() == host.lowercased(),
              url.user() == nil, url.password() == nil, url.port == nil else { throw .wrongOrigin }
        let encoded = url.path(percentEncoded: true).split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard encoded.first == Substring(rootSegment) else { throw .outsideWorkspace }
        var decoded: [String] = []
        for segment in encoded.dropFirst() {
            guard let value = segment.removingPercentEncoding else { throw .outsideWorkspace }
            decoded.append(value)
        }
        let segments = try workspaceSegments(decoded, allowsCurrentDirectory: false)
        guard let name = segments.last else { throw .outsideWorkspace }
        let nameParts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard nameParts.count > 1, let fileExtension = nameParts.last, let kind = kinds[fileExtension.lowercased()]
        else { throw .unsupportedType }
        return Resource(path: segments.joined(separator: "/"), kind: kind)
    }

    /// Plain names only: `..`, separators and control characters never reach the daemon.
    private static func workspaceSegments(_ segments: [String], allowsCurrentDirectory: Bool) throws(Rejection) -> [String] {
        var result: [String] = []
        for (index, segment) in segments.enumerated() {
            if allowsCurrentDirectory, segment == "." || (segment.isEmpty && index == 0) { continue }
            guard !segment.isEmpty, segment != ".", segment != "..",
                  !segment.contains("/"), !segment.contains("\\"), !segment.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
            else { throw .outsideWorkspace }
            result.append(segment)
        }
        return result
    }

    /// Bytes must match the declared type, so a renamed HTML file never loads as an image.
    static func validate(_ data: Data, as kind: Kind) throws(Rejection) {
        switch kind {
        case .image:
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, options),
                  let type = CGImageSourceGetType(source) as String?, imageTypes.contains(type),
                  CGImageSourceGetCount(source) > 0 else { throw .invalidContent }
        case .stylesheet:
            guard !data.contains(0), String(data: data, encoding: .utf8) != nil else { throw .invalidContent }
        case .font(let mimeType):
            let signatures = fontSignatures[mimeType] ?? []
            guard signatures.contains(where: { data.starts(with: $0) }) else { throw .invalidContent }
        }
    }

    /// The report's CSP: inline styles plus this scheme's images, stylesheets and fonts.
    /// Scripts, frames, media, connections, forms and `<base>` stay denied.
    static let contentSecurityPolicy = "default-src 'none'; style-src 'unsafe-inline' \(scheme):; img-src data: \(scheme):; "
        + "font-src \(scheme):; base-uri 'none'; form-action 'none'"
}

/// Serves a report's relative images, stylesheets and fonts from its own workspace
/// through the daemon's file read, which still enforces workspace containment.
/// WebKit calls `WKURLSchemeHandler` on the main thread, so MainActor isolation is correct here.
final class HTMLFileResourceHandler: NSObject, WKURLSchemeHandler {
    typealias Fetch = (_ workspaceId: String, _ path: String, _ limit: Int) async throws -> Data

    let workspaceId: String
    let host = UUID().uuidString.lowercased()
    private let fetch: Fetch
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// Bytes delivered to the current page, plus the limits of its loads still in flight,
    /// so concurrent loads can never together exceed the page cap.
    private var servedBytes = 0
    private var reservedBytes = 0
    private var requestCount = 0
    /// Increments per page so a previous page's late completion never touches the new budget.
    private var pageGeneration = 0

    init(workspaceId: String, fetch: @escaping Fetch) {
        self.workspaceId = workspaceId
        self.fetch = fetch
    }

    convenience init(workspaceId: String, loader: WorkspaceFileImageLoader) {
        self.init(workspaceId: workspaceId) { workspaceId, path, limit in
            try await WorkspaceFileImageLoader.fetchBytes(
                chunkRequester: loader.chunkRequester,
                workspaceId: workspaceId,
                path: path,
                limit: limit,
                length: WorkspaceFileImageLoader.pdfChunkLength
            )
        }
    }

    /// Cancels the previous page's loads, starts a fresh per-page budget and returns the page's base URL.
    func beginPage(filePath: String) -> URL? {
        cancelAll()
        pageGeneration += 1
        servedBytes = 0
        reservedBytes = 0
        requestCount = 0
        return HTMLFileResourcePolicy.baseURL(host: host, filePath: filePath)
    }

    func webView(_: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        tasks[id] = Task { [weak self] in
            let result: Result<(URLResponse, Data), HTMLFileResourcePolicy.Rejection>
            if let self {
                result = await load(urlSchemeTask.request.url)
            } else {
                result = .failure(.pageBudgetExhausted)
            }
            // WebKit raises if a stopped task receives anything.
            guard !Task.isCancelled, self?.tasks.removeValue(forKey: id) != nil else { return }
            switch result {
            case .success(let (response, data)):
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            case .failure(let rejection):
                urlSchemeTask.didFailWithError(Self.error(for: rejection))
            }
        }
    }

    func webView(_: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    func load(_ url: URL?) async -> Result<(URLResponse, Data), HTMLFileResourcePolicy.Rejection> {
        do {
            guard let url else { throw HTMLFileResourcePolicy.Rejection.wrongOrigin }
            let resource = try HTMLFileResourcePolicy.resource(for: url, host: host)
            guard requestCount < HTMLFileResourcePolicy.maxPageRequests else { throw HTMLFileResourcePolicy.Rejection.pageBudgetExhausted }
            requestCount += 1
            let limit = min(
                HTMLFileResourcePolicy.maxResourceBytes,
                HTMLFileResourcePolicy.maxPageBytes - servedBytes - reservedBytes
            )
            guard limit > 0 else { throw HTMLFileResourcePolicy.Rejection.pageBudgetExhausted }
            // Reserve the whole limit up front; release it, keeping only the delivered bytes, when the load ends.
            let generation = pageGeneration
            reservedBytes += limit
            var delivered = 0
            defer {
                if generation == pageGeneration {
                    reservedBytes -= limit
                    servedBytes += delivered
                }
            }
            let data: Data
            do {
                data = try await fetch(workspaceId, resource.path, limit)
            } catch WorkspaceFileImageLoader.LoadError.fileTooLarge {
                throw HTMLFileResourcePolicy.Rejection.tooLarge
            } catch {
                throw HTMLFileResourcePolicy.Rejection.invalidContent
            }
            guard generation == pageGeneration else { throw HTMLFileResourcePolicy.Rejection.pageBudgetExhausted }
            guard data.count <= limit else { throw HTMLFileResourcePolicy.Rejection.tooLarge }
            try HTMLFileResourcePolicy.validate(data, as: resource.kind)
            delivered = data.count
            let response = URLResponse(
                url: url,
                mimeType: resource.kind.mimeType,
                expectedContentLength: data.count,
                textEncodingName: resource.kind == .stylesheet ? "utf-8" : nil
            )
            return .success((response, data))
        } catch let rejection as HTMLFileResourcePolicy.Rejection {
            return .failure(rejection)
        } catch {
            return .failure(.invalidContent)
        }
    }

    private static func error(for rejection: HTMLFileResourcePolicy.Rejection) -> URLError {
        switch rejection {
        case .wrongOrigin, .outsideWorkspace: URLError(.noPermissionsToReadFile)
        case .unsupportedType, .invalidContent: URLError(.cannotDecodeContentData)
        case .tooLarge, .pageBudgetExhausted: URLError(.dataLengthExceedsMaximum)
        }
    }
}
