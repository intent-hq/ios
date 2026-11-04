import Foundation

nonisolated struct MobileTerminal: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let workspaceId: String
    let daemonBootId: String
    let name: String
}

/// The program running in a terminal, from the daemon's `foregroundProcess` and
/// `lastProcess` fields. Nil when the terminal has only ever run its shell.
nonisolated struct MobileTerminalProcess: Equatable, Sendable {
    let foreground: String?
    let last: String?

    init?(_ data: [String: Any]) {
        foreground = Self.name(data["foregroundProcess"])
        last = Self.name(data["lastProcess"])
        if foreground == nil, last == nil { return nil }
    }

    var title: String? { foreground ?? last }
    var hasExited: Bool { foreground == nil && last != nil }

    private static func name(_ value: Any?) -> String? {
        guard let name = value as? String, !name.isEmpty else { return nil }
        return name
    }
}

enum MobileTerminalError: LocalizedError {
    case disconnected
    case invalidResponse
    case sessionEnded

    var errorDescription: String? {
        switch self {
        case .disconnected: "The connection was interrupted. Reconnect before using this terminal."
        case .invalidResponse: "The server returned an unexpected terminal response."
        case .sessionEnded: "This terminal session has ended. Use New terminal to start another."
        }
    }
}

@MainActor
final class MobileTerminalPersistence {
    private let defaults: UserDefaults
    private let key: String?
    private let namesKey: String?

    init(backendID: BackendID?, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = backendID.map { "mobileTerminals.\($0.connectionID.uuidString)" }
        namesKey = backendID.map { "mobileTerminalNames.\($0.connectionID.uuidString)" }
    }

    func load() -> [MobileTerminal] {
        guard let key, let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([MobileTerminal].self, from: data)) ?? []
    }

    func save(_ terminals: [MobileTerminal]) {
        guard let key, let data = try? JSONEncoder().encode(terminals) else { return }
        defaults.set(data, forKey: key)
    }

    /// Names the user gave terminals, by terminal id.
    func loadNames() -> [String: String] {
        guard let namesKey else { return [:] }
        return defaults.dictionary(forKey: namesKey) as? [String: String] ?? [:]
    }

    func saveNames(_ names: [String: String]) {
        guard let namesKey else { return }
        defaults.set(names, forKey: namesKey)
    }
}
