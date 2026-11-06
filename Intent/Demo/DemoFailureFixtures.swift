#if DEBUG
import Foundation

/// Debug-only failure seams for the hands-on check of error states:
/// `--demo-failures=pr-search,pr-load-more,pr-detail,file-preview` with
/// `--demo-data`. Each failure fires once per launch, so Retry recovers.
enum DemoFailureFixtures {
    private static let argumentPrefix = "--demo-failures="
    private static let nextToken = "demo-failure-page-2"
    private static let firstPageSize = 2
    private static let largeFile = "docs/Large screenshot.png"
    private static let corruptFile = "docs/Corrupt photo.png"
    private static let offlineFile = "docs/Offline photo.png"
    private static let garbledFile = "docs/Garbled reply.png"
    private static var fired: Set<String> = []
    /// Matches the wording of the live connection's request timeout.
    private static let requestTimedOut = NSError(
        domain: "DemoFailureFixtures", code: 0, userInfo: [NSLocalizedDescriptionKey: "Request timed out"]
    )

    private static var enabled: Set<String> {
        let arguments = LaunchOptions.current.arguments
        guard DemoMode.demoDataRequested(by: arguments),
              let value = arguments.first(where: { $0.hasPrefix(argumentPrefix) }) else { return [] }
        return Set(value.dropFirst(argumentPrefix.count).split(separator: ",").map(String.init))
    }

    /// True the first time `name` is asked for while enabled.
    private static func firesOnce(_ name: String) -> Bool {
        guard enabled.contains(name), !fired.contains(name) else { return false }
        fired.insert(name)
        return true
    }

    static func response(for method: String, params: [String: Any]) throws -> Any? {
        switch method {
        case "github.pulls.search":
            return try searchResponse(params: params)
        case "github.pulls.get":
            return firesOnce("pr-detail") ? ["pull": "unexpected"] : nil
        case "file.list" where enabled.contains("file-preview") && params["path"] as? String == "docs":
            return [largeFile, corruptFile, offlineFile, garbledFile].map { ["name": URL(fileURLWithPath: $0).lastPathComponent, "type": "file"] }
        case "file.readChunk" where enabled.contains("file-preview"):
            return try fileResponse(path: params["path"] as? String, params: params)
        default:
            return nil
        }
    }

    private static func searchResponse(params: [String: Any]) throws -> Any? {
        if firesOnce("pr-search") { return ["unexpected": true] }
        guard enabled.contains("pr-load-more"),
              let page = DemoPullRequestFixtures.response(for: "github.pulls.search", params: params) as? [String: Any],
              let pulls = page["pulls"] as? [[String: Any]] else { return nil }
        if params["nextToken"] as? String == nextToken {
            if firesOnce("pr-load-more") { throw requestTimedOut }
            return ["pulls": Array(pulls.dropFirst(firstPageSize))]
        }
        guard pulls.count > firstPageSize else { return page }
        return ["pulls": Array(pulls.prefix(firstPageSize)), "nextToken": nextToken]
    }

    private static func fileResponse(path: String?, params: [String: Any]) throws -> Any? {
        let bytes: Data
        switch path {
        case largeFile:
            // swiftlint:disable:next no_magic_numbers
            return ["content": "", "bytesRead": 0, "size": 40 * 1024 * 1024]
        case corruptFile:
            bytes = Data("This is not an image.".utf8)
        case offlineFile:
            if firesOnce("file-preview") { throw requestTimedOut }
            bytes = DemoFixtures.statusImagePNG
        case garbledFile:
            if fired.insert(garbledFile).inserted { return ["unexpected": true] }
            bytes = DemoFixtures.statusImagePNG
        default:
            return nil
        }
        let offset = params["offset"] as? Int ?? 0
        let length = params["length"] as? Int ?? 0
        let chunk = bytes.dropFirst(max(0, offset)).prefix(max(0, length))
        return ["content": chunk.base64EncodedString(), "bytesRead": chunk.count, "size": bytes.count]
    }
}
#endif
