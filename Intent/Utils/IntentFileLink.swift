import Foundation

/// Parsed `intent://local/[ws-id/]file/<path>` workspace-file link.
///
/// Grammar (mirrors the desktop intent link grammar):
///   intent://local/file/<workspace-relative-path>          — current workspace
///   intent://local/{workspace-id}/file/<path>              — explicit workspace
///
/// The path may contain slashes; everything after the `file` segment is the
/// workspace-relative path. Segments are percent-decoded on parse.
nonisolated struct IntentFileLink: Equatable {
    /// Explicit workspace ID from the long form, nil for the short form.
    let workspaceId: String?
    /// Workspace-relative file path (percent-decoded).
    let path: String

    /// Image extensions rendered inline (desktop parity; no SVG in v1).
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    /// Whether the linked file's extension is in the inline-image allowlist.
    var isImage: Bool {
        Self.imageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    /// Parse an intent:// URL into a file link; nil for anything that is not
    /// an `intent://local/[ws-id/]file/<path>` URL (note/task links, other
    /// schemes, missing path) or whose path looks traversal-shaped.
    static func parse(_ url: URL) -> Self? {
        guard url.scheme == "intent", url.host == "local" else { return nil }
        // Split the raw (still percent-encoded) path so doubled slashes and
        // encoded slashes (%2F) stay visible, then decode each segment. The
        // daemon's resolve_within containment is the real boundary; this is
        // defense-in-depth + parity with the desktop parser, which rejects
        // traversal-shaped links client-side.
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

    /// Parse a workspace file link that an agent wrote as a path instead of an
    /// `intent://` link: a relative path (`report.html`, `./docs/notes.txt`),
    /// an absolute path, or a `file://` URL with no host (or `localhost`).
    ///
    /// Relative paths are workspace-relative. Absolute paths are passed through
    /// unchanged: the phone can't know the workspace folder on the Mac, but the
    /// daemon's `file.read` accepts an absolute path that lies inside the
    /// workspace and rejects one outside it, so the viewer shows its error.
    /// Returns nil for any other scheme, a host-qualified path (`//host/x`),
    /// an empty path (`#summary`) or a traversal-shaped segment, so those
    /// links keep showing the Can't Open Link message.
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

    /// A bare path with no host, or a `file://` URL on this machine (no host or `localhost`).
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

    /// Rejects post-decode segments that are empty (doubled/trailing slash),
    /// relative (`.`/`..`), or contain a backslash or a slash smuggled in via
    /// percent-encoding — mirrors FE's isSafeWorkspaceRelativePath.
    private static func isSafeSegment(_ segment: String) -> Bool {
        !segment.isEmpty && segment != "." && segment != ".."
            && !segment.contains("\\") && !segment.contains("/")
    }
}
