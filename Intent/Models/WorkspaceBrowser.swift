import Foundation

nonisolated struct WorkspaceBrowser: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let workspaceId: String
    let title: String
    let url: String
    let command: String?

    static func detected(script: [String: Any], workspaceId: String) -> WorkspaceBrowser? {
        guard let id = script["id"] as? String, !id.isEmpty,
              script["workspaceId"] as? String == workspaceId,
              let runtime = script["runtime"] as? [String: Any],
              runtime["status"] as? String == "running",
              let rawURL = runtime["detectedUrl"] as? String,
              let url = try? WorkspaceBrowserURL.normalize(rawURL),
              let command = script["command"] as? String else { return nil }
        let name = (script["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkspaceBrowser(
            id: "script:\(id)", workspaceId: workspaceId,
            title: name.flatMap { $0.isEmpty ? nil : $0 } ?? url,
            url: url, command: command
        )
    }
}

nonisolated enum WorkspaceBrowserError: LocalizedError {
    case invalidResponse
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The server returned an unexpected browser response."
        case .invalidURL: "Enter an http or https address without a username or password, such as localhost:3000."
        }
    }
}

nonisolated enum WorkspaceBrowserURL {
    private static let maximumPort = 65_535
    private static let localAliases: Set<String> = ["localhost", "daemon.localhost", "0.0.0.0", "[::]", "[::1]"]

    static func normalize(_ input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              !trimmed.contains("\\") else { throw WorkspaceBrowserError.invalidURL }
        let hasScheme = trimmed.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil
        let qualified = hasScheme ? trimmed : "http://\(trimmed)"
        guard let parsed = URL(string: qualified, encodingInvalidCharacters: false),
              var components = URLComponents(url: parsed, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              !host.contains("%"), parsed.host != nil else { throw WorkspaceBrowserError.invalidURL }
        if let port = components.port, !(1...maximumPort).contains(port) {
            throw WorkspaceBrowserError.invalidURL
        }
        // An empty explicit port is not a usable host:port entry.
        let authority = qualified.dropFirst("\(scheme)://".count).prefix { !"/?#".contains($0) }
        guard !authority.hasSuffix(":") else { throw WorkspaceBrowserError.invalidURL }
        components.scheme = scheme
        let normalizedHost = host.lowercased()
        components.host = localAliases.contains(normalizedHost) ? "127.0.0.1" : normalizedHost
        guard let normalized = components.url?.absoluteString else { throw WorkspaceBrowserError.invalidURL }
        return normalized
    }
}

@MainActor
final class WorkspaceBrowserPersistence {
    private let defaults: UserDefaults
    private let key: String?

    init(backendID: BackendID?, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = backendID.map { "workspaceBrowsers.\($0.connectionID.uuidString)" }
    }

    func load() -> [WorkspaceBrowser] {
        guard let key, let data = defaults.data(forKey: key),
              let browsers = try? JSONDecoder().decode([WorkspaceBrowser].self, from: data) else { return [] }
        return browsers.filter { $0.command == nil && (try? WorkspaceBrowserURL.normalize($0.url)) == $0.url }
    }

    func save(_ browsers: [WorkspaceBrowser]) {
        guard let key, let data = try? JSONEncoder().encode(browsers) else { return }
        defaults.set(data, forKey: key)
    }
}
