import Foundation
@testable import Intent
import Testing
import UIKit
import WebKit

@MainActor
enum HTMLFileResourceTestSupport {
    typealias Rejection = HTMLFileResourcePolicy.Rejection

    @MainActor
    final class FetchGate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        var waiting: Int { waiters.count }

        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            released = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    final class RecordingSchemeTask: NSObject, WKURLSchemeTask {
        let request: URLRequest
        private(set) var callbacks: [String] = []

        init(url: URL) { request = URLRequest(url: url) }

        func didReceive(_: URLResponse) { callbacks.append("response") }
        func didReceive(_: Data) { callbacks.append("data") }
        func didFinish() { callbacks.append("finish") }
        func didFailWithError(_: any Error) { callbacks.append("fail") }
    }

    static func handler(serving files: [String: Data], fetched: ((String, Int) -> Void)? = nil) -> HTMLFileResourceHandler {
        HTMLFileResourceHandler(workspaceId: "ws-a") { workspaceId, path, limit in
            #expect(workspaceId == "ws-a")
            fetched?(path, limit)
            guard let data = files[path] else { throw URLError(.fileDoesNotExist) }
            guard data.count <= limit else { throw WorkspaceFileImageLoader.LoadError.fileTooLarge }
            return data
        }
    }

    static func load(_ reference: String, with handler: HTMLFileResourceHandler, base: URL) async -> Result<Data, Rejection> {
        let url = URL(string: reference, relativeTo: base)?.absoluteURL
        return await handler.load(url).map(\.1)
    }

    static func paddedPNG(byteCount: Int) -> Data {
        var png = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { _ in }
        png.append(Data(count: max(0, byteCount - png.count)))
        return png
    }

    private static let maximumSettleYields = 1000

    static func settle(until condition: () -> Bool) async {
        for _ in 0..<maximumSettleYields where !condition() {
            await Task.yield()
        }
    }
}
