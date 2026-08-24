import Foundation

/// Parsed `intent://local/[ws-id/]file/<path>` workspace-file link.
///
/// Grammar (mirrors the desktop intent link grammar):
///   intent://local/file/<workspace-relative-path>          — current workspace
///   intent://local/{workspace-id}/file/<path>              — explicit workspace
///
/// The path may contain slashes; everything after the `file` segment is the
/// workspace-relative path. Segments are percent-decoded on parse.
struct IntentFileLink: Equatable {
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
    /// schemes, missing path).
    static func parse(_ url: URL) -> IntentFileLink? {
        guard url.scheme == "intent", url.host == "local" else { return nil }
        // URL.pathComponents percent-decodes each segment.
        let segments = url.pathComponents.filter { $0 != "/" }
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
}
