import Foundation

/// A saved asset belongs to the URL's workspace and has one percent-decoded
/// identifier. Query/fragment hints are not part of its identity; in particular,
/// a Markdown-authored backend hint must never select a different session.
nonisolated struct WorkspaceAssetLink: Equatable {
    let workspaceId: String
    let assetId: String

    static func parse(_ url: URL) -> Self? {
        guard url.scheme?.lowercased() == "workspace-asset",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil,
              let workspaceId = components.host, isSafeIdentifier(workspaceId),
              components.percentEncodedPath.hasPrefix("/"),
              let assetId = String(components.percentEncodedPath.dropFirst()).removingPercentEncoding,
              isSafeIdentifier(assetId)
        else { return nil }
        return Self(workspaceId: workspaceId, assetId: assetId)
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\")
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
}
