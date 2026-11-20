import Foundation

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
