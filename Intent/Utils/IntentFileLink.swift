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
        Self.imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Parse an intent:// URL into a file link; nil for anything that is not
    /// an `intent://local/[ws-id/]file/<path>` URL (note/task links, other
    /// schemes, missing path) or whose path looks traversal-shaped.
    static func parse(_ url: URL) -> IntentFileLink? {
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
        return IntentFileLink(workspaceId: workspaceId, path: pathSegments.joined(separator: "/"))
    }

    /// Rejects post-decode segments that are empty (doubled/trailing slash),
    /// relative (`.`/`..`), or contain a backslash or a slash smuggled in via
    /// percent-encoding — mirrors FE's isSafeWorkspaceRelativePath.
    private static func isSafeSegment(_ segment: String) -> Bool {
        !segment.isEmpty && segment != "." && segment != ".."
            && !segment.contains("\\") && !segment.contains("/")
    }
}
