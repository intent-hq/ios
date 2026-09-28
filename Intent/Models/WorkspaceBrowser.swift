import Foundation

nonisolated struct WorkspaceBrowser: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let workspaceId: String
    let title: String
    let url: String
    let command: String?

    var isSavedSession: Bool { id.hasPrefix("browser:") }

    static func detected(script: [String: Any], workspaceId: String) -> Self? {
        guard let id = script["id"] as? String, !id.isEmpty,
              script["workspaceId"] as? String == workspaceId,
              let runtime = script["runtime"] as? [String: Any],
              runtime["status"] as? String == "running",
              let rawURL = runtime["detectedUrl"] as? String,
              let url = try? WorkspaceBrowserURL.normalize(rawURL),
              let command = script["command"] as? String else { return nil }
        let name = (script["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(
            id: "script:\(id)",
            workspaceId: workspaceId,
            title: name.flatMap { $0.isEmpty ? nil : $0 } ?? url,
            url: url,
            command: command
        )
    }

    static func detected(tab: [String: Any], workspaceId: String) -> Self? {
        guard let id = tab["tabId"] as? String, !id.isEmpty,
              tab["workspaceId"] as? String == workspaceId,
              let rawURL = tab["url"] as? String,
              let url = WorkspaceBrowserURL.tabURL(current: rawURL, requested: tab["requestedUrl"] as? String) else {
            return nil
        }
        let title = (tab["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(
            id: "tab:\(id)",
            workspaceId: workspaceId,
            title: title.flatMap { $0.isEmpty ? nil : $0 } ?? url,
            url: url,
            command: nil
        )
    }

    static func merging(scripts: [Self], tabs: [Self]) -> [Self] {
        var browsers = scripts
        var mergedScriptIds: Set<String> = []
        for tab in tabs {
            if let index = browsers.firstIndex(where: { browser in
                browser.command != nil && !mergedScriptIds.contains(browser.id)
                    && WorkspaceBrowserURL.matchesServer(tab.url, server: browser.url)
            }) {
                let script = browsers[index]
                browsers[index] = Self(
                    id: script.id,
                    workspaceId: script.workspaceId,
                    title: script.title,
                    url: tab.url,
                    command: script.command
                )
                mergedScriptIds.insert(script.id)
            } else if !browsers.contains(where: { $0.url == tab.url }) {
                browsers.append(tab)
            }
        }
        return browsers
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
    private static let httpPort = 80
    private static let httpsPort = 443
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

    static func tabURL(current: String, requested: String?) -> String? {
        let currentURL = try? normalize(current)
        guard let requested, let requestedURL = try? normalize(requested) else { return currentURL }
        guard let currentURL else {
            return current.isEmpty || current == "about:blank" ? requestedURL : nil
        }
        if origin(currentURL) == origin(requestedURL) { return currentURL }
        // The registry retains the pre-rewrite address and rebases its path as
        // the desktop navigates. Its loaded address can use a desktop-only port.
        let host = URLComponents(string: requestedURL)?.host
        return host == "127.0.0.1" || host == "client.localhost" ? requestedURL : currentURL
    }

    static func matchesServer(_ tab: String, server: String) -> Bool {
        if tab == server { return true }
        guard origin(tab) == origin(server), let components = URLComponents(string: server) else { return false }
        return ["", "/"].contains(components.path) && components.query == nil && components.fragment == nil
    }

    private static func origin(_ url: String) -> String? {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme, let host = components.host else { return nil }
        let port = components.port ?? (scheme == "https" ? httpsPort : httpPort)
        return "\(scheme)://\(host):\(port)"
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
        return browsers.filter { $0.isSavedSession && (try? WorkspaceBrowserURL.normalize($0.url)) == $0.url }
    }

    func save(_ browsers: [WorkspaceBrowser]) {
        guard let key, let data = try? JSONEncoder().encode(browsers) else { return }
        defaults.set(data, forKey: key)
    }

    func loadDismissed() -> [String: Set<String>] {
        guard let key, let data = defaults.data(forKey: "\(key).dismissed") else { return [:] }
        return (try? JSONDecoder().decode([String: Set<String>].self, from: data)) ?? [:]
    }

    func saveDismissed(_ dismissed: [String: Set<String>]) {
        guard let key, let data = try? JSONEncoder().encode(dismissed) else { return }
        defaults.set(data, forKey: "\(key).dismissed")
    }
}
