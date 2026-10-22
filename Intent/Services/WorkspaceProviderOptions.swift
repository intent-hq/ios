import Foundation
import Observation

/// Host policy for creation forms. A refresh hides the previous choices until
/// catalog, settings and authentication have all been read successfully.
@MainActor
@Observable final class WorkspaceProviderOptions {
    enum State: Equatable {
        case failed
        case idle
        case loaded([ProviderInfo])
        case loading
    }

    private(set) var state: State = .idle
    private(set) var hasAttemptedLoad = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    private var generation = 0
    private let connectionManager: ConnectionManagerRouting

    var providers: [ProviderInfo] {
        guard case let .loaded(providers) = state else { return [] }
        return providers
    }

    var isLoading: Bool { state == .idle || state == .loading }

    var guidance: String? {
        switch state {
        case .failed:
            "Couldn’t load provider settings from this host. Retry, or check that the host is up to date."
        case .loaded where providers.isEmpty:
            "No providers are enabled on this host. Enable a provider in Settings, then retry."
        default:
            nil
        }
    }

    init(connectionManager: ConnectionManagerRouting) {
        self.connectionManager = connectionManager
    }

    func invalidate() {
        generation &+= 1
        loadTask = nil
        state = .idle
    }

    func reloadIfNeeded() async {
        guard hasAttemptedLoad else { return }
        await load()
    }

    /// Always revalidate on sheet open or retry, joining concurrent callers.
    /// Failed/unsupported reads never fall back to the unfiltered auth list.
    func load() async {
        hasAttemptedLoad = true
        if let loadTask {
            await loadTask.value
            return
        }
        let startedAt = generation
        state = .loading
        let task = Task { await fetch(generation: startedAt) }
        loadTask = task
        await task.value
        guard startedAt == generation else { return }
        loadTask = nil
    }

    private func fetch(generation startedAt: Int) async {
        do {
            guard startedAt == generation else { return }
            let catalog = try await connectionManager.request("providers.catalog")
            guard startedAt == generation else { return }
            let settings = try await connectionManager.request("settings.get", params: ["path": "providers.enabled"])
            guard startedAt == generation else { return }
            let authentication = try await connectionManager.request("host.providerAuthStatus")
            guard startedAt == generation else { return }
            state = .loaded(try Self.decode(catalog: catalog, settings: settings, authentication: authentication))
        } catch {
            guard startedAt == generation else { return }
            state = .failed
            AppLog.agents.error("[WorkspaceProviderOptions] provider settings load failed: \(error)")
        }
    }

    static func decode(catalog: Any, settings: Any, authentication: Any) throws -> [ProviderInfo] {
        let decoder = JSONDecoder()
        let catalog = try decoder.decode(Catalog.self, from: JSONSerialization.data(withJSONObject: catalog))
        let settings = try decoder.decode(Enablement.self, from: JSONSerialization.data(withJSONObject: settings))
        let authentication = try decoder.decode(
            Authentication.self, from: JSONSerialization.data(withJSONObject: authentication)
        )
        guard settings.path == "providers.enabled",
              Set(catalog.providers.map(\.id)).count == catalog.providers.count,
              catalog.providers.allSatisfy({ !$0.id.isEmpty }) else {
            throw CocoaError(.coderReadCorrupt)
        }
        let enabledProviders = catalog.providers.filter { entry in
            entry.visible && (!entry.canBeDisabled || settings.value[entry.id] == true)
        }
        return enabledProviders.map { entry in
            let status: ProviderAuthentication
            let authenticationEntry = authentication.providers.first { $0.id == entry.id }
            switch authenticationEntry?.authenticated {
            case true: status = .signedIn
            case false: status = .signedOut
            case nil: status = .unknown
            }
            return ProviderInfo(id: entry.id, authenticated: status)
        }
    }
}

private extension WorkspaceProviderOptions {
    struct Catalog: Decodable {
        let providers: [CatalogEntry]
    }

    struct CatalogEntry: Decodable {
        let id: String
        let visible: Bool
        let canBeDisabled: Bool
    }

    struct Enablement: Decodable {
        let path: String
        let value: [String: Bool]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: EnablementCodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            // The host returns null for an unset map, but a missing value is
            // an invalid response. Strict Bool decoding rejects numeric flags.
            value = try container.decodeNil(forKey: .value) ? [:] : container.decode([String: Bool].self, forKey: .value)
        }
    }

    enum EnablementCodingKeys: String, CodingKey {
        case path
        case value
    }

    struct Authentication: Decodable {
        let providers: [AuthenticationEntry]
    }

    struct AuthenticationEntry: Decodable {
        let id: String
        // Missing or null authentication decodes as unknown, not an explicit signed-out result.
        // swiftlint:disable:next discouraged_optional_boolean
        let authenticated: Bool?
    }
}
