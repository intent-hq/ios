import Foundation

nonisolated struct MobileTerminal: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let workspaceId: String
    let daemonBootId: String
    let name: String
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

    init(backendID: BackendID?, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = backendID.map { "mobileTerminals.\($0.connectionID.uuidString)" }
    }

    func load() -> [MobileTerminal] {
        guard let key, let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([MobileTerminal].self, from: data)) ?? []
    }

    func save(_ terminals: [MobileTerminal]) {
        guard let key, let data = try? JSONEncoder().encode(terminals) else { return }
        defaults.set(data, forKey: key)
    }
}
