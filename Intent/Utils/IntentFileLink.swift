import Foundation

nonisolated struct IntentFileLink: Equatable {
    let workspaceId: String?
    let path: String

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    var isImage: Bool {
        Self.imageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    static func parse(_ url: URL) -> Self? {
        guard url.scheme == "intent", url.host == "local" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let rawPath = components.percentEncodedPath
        guard rawPath.hasPrefix("/") else { return nil }
        var segments: [String] = []
        for raw in rawPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            guard let decoded = String(raw).removingPercentEncoding,
                  Self.isSafeSegment(decoded)
            else { return nil }
            segments.append(decoded)
        }
        guard !segments.isEmpty else { return nil }

        let workspaceId: String?
        let pathSegments: ArraySlice<String>
        if segments[0] == "file" {
            workspaceId = nil
            pathSegments = segments.dropFirst()
        } else if segments.count >= 2, segments[1] == "file" {
            workspaceId = segments[0]
            pathSegments = segments.dropFirst(2)
        } else {
            return nil
        }
        guard !pathSegments.isEmpty else { return nil }
        return Self(workspaceId: workspaceId, path: pathSegments.joined(separator: "/"))
    }

    static func parsePath(_ url: URL) -> Self? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              Self.isLocalPath(components)
        else { return nil }
        var rawPath = Substring(components.percentEncodedPath)
        let isAbsolute = rawPath.hasPrefix("/")
        if isAbsolute {
            rawPath = rawPath.dropFirst()
        } else if rawPath.hasPrefix("./") {
            rawPath = rawPath.dropFirst(2)
        }
        guard components.scheme == nil || isAbsolute else { return nil }
        var segments: [String] = []
        for raw in rawPath.split(separator: "/", omittingEmptySubsequences: false) {
            guard let decoded = String(raw).removingPercentEncoding,
                  Self.isSafeSegment(decoded)
            else { return nil }
            segments.append(decoded)
        }
        let path = segments.joined(separator: "/")
        return Self(workspaceId: nil, path: isAbsolute ? "/" + path : path)
    }

    private static func isLocalPath(_ components: URLComponents) -> Bool {
        switch components.scheme?.lowercased() {
        case nil:
            components.host == nil
        case "file":
            components.percentEncodedHost.map { $0.isEmpty || $0.lowercased() == "localhost" } ?? true
        default:
            false
        }
    }

    private static func isSafeSegment(_ segment: String) -> Bool {
        !segment.isEmpty && segment != "." && segment != ".."
            && !segment.contains("\\") && !segment.contains("/")
    }
}
