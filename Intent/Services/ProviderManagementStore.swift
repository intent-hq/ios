import Foundation
import Observation

/// Settings and authentication belong to this connection's host, never to the phone.
@MainActor
@Observable final class ProviderManagementStore {
    struct Provider: Identifiable, Equatable {
        let id: String
        let name: String
        let canBeDisabled: Bool
        let supportsTestPrompt: Bool
        let loginDocsURL: URL?
        var enabled: Bool
        var authentication: ProviderAuthentication
    }

    private(set) var providers: [Provider] = []
    private(set) var isBusy = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    private(set) var testMessages: [String: String] = [:]
    private let connectionManager: ConnectionManagerRouting
    private var generation = 0
    private var isFresh = false
    private static let testTimeout: TimeInterval = 180

    var canManage: Bool { hasLoaded && isFresh && !isBusy && connectionManager.connectionState == .connected }

    init(connectionManager: ConnectionManagerRouting) {
        self.connectionManager = connectionManager
    }

    /// The view calls this on disconnect and dismissal; late replies cannot revive its state.
    func invalidate() {
        generation &+= 1
        providers = []
        hasLoaded = false
        isFresh = false
        isBusy = false
        errorMessage = nil
        testMessages = [:]
    }

    func load() async {
        guard !isBusy else { return }
        guard connectionManager.connectionState == .connected else {
            errorMessage = "Reconnect to this host, then retry loading providers."
            return
        }
        let startedAt = generation
        isBusy = true
        errorMessage = nil
        defer { if startedAt == generation { isBusy = false } }
        do {
            let catalog: Catalog = try await request("providers.catalog", generation: startedAt)
            let settings: Enablement = try await request(
                "settings.get", generation: startedAt, params: ["path": "providers.enabled"]
            )
            let authentication: Authentication = try await request(
                "host.providerAuthStatus", generation: startedAt, params: ["force": true]
            )
            providers = try Self.makeProviders(catalog, settings: settings, authentication: authentication)
            hasLoaded = true
            isFresh = true
        } catch {
            let retained = hasLoaded ? " Showing the last confirmed settings." : ""
            fail("Couldn’t refresh providers. Check the host connection and retry." + retained, generation: startedAt)
        }
    }

    func setEnabled(_ enabled: Bool, providerID: String) async {
        guard canManage, let provider = providers.first(where: { $0.id == providerID }),
              provider.canBeDisabled, provider.enabled != enabled else { return }
        let startedAt = generation
        isBusy = true
        errorMessage = nil
        defer { if startedAt == generation { isBusy = false } }
        do {
            // The wire replaces the whole map. Re-read immediately before writing
            // so unrelated and unknown provider entries are preserved.
            let current: Enablement = try await request(
                "settings.get", generation: startedAt, params: ["path": "providers.enabled"]
            )
            var value = try current.validatedValue()
            value[providerID] = enabled
            _ = try await connectionManager.request("settings.update", params: [
                "changes": [["path": "providers.enabled", "value": value]]
            ])
            try checkGeneration(startedAt)
            let confirmed: Enablement = try await request(
                "settings.get", generation: startedAt, params: ["path": "providers.enabled"]
            )
            let confirmedValue = try confirmed.validatedValue()
            for index in providers.indices {
                providers[index].enabled = !providers[index].canBeDisabled || confirmedValue[providers[index].id] == true
            }
            guard confirmedValue[providerID] == enabled else {
                throw CocoaError(.coderReadCorrupt)
            }
        } catch {
            fail("Couldn’t confirm the provider change. Retry loading, then try the switch again.", generation: startedAt)
        }
    }

    func testProvider(_ providerID: String) async {
        guard canManage, let provider = providers.first(where: { $0.id == providerID }),
              provider.enabled, provider.supportsTestPrompt else { return }
        let startedAt = generation
        isBusy = true
        errorMessage = nil
        testMessages[providerID] = nil
        defer { if startedAt == generation { isBusy = false } }
        do {
            let response = try await connectionManager.request(
                "host.providerTestPrompt", params: ["providerId": providerID], timeout: Self.testTimeout
            )
            try checkGeneration(startedAt)
            let result = try Self.decode(TestResult.self, response)
            testMessages[providerID] = result.guidance
            let authentication: Authentication = try await request(
                "host.providerAuthStatus", generation: startedAt
            )
            try authentication.validate()
            for index in providers.indices {
                providers[index].authentication = authentication.status(for: providers[index].id)
            }
        } catch {
            fail(
                "Couldn’t finish checking this provider. Retry loading its status before testing again.",
                generation: startedAt
            )
        }
    }

    private func request<Response: Decodable>(
        _ method: String, generation: Int, params: [String: Any] = [:]
    ) async throws -> Response {
        try checkGeneration(generation)
        let response = try await connectionManager.request(method, params: params)
        try checkGeneration(generation)
        return try Self.decode(Response.self, response)
    }

    private func checkGeneration(_ startedAt: Int) throws {
        try Task.checkCancellation()
        guard startedAt == generation, connectionManager.connectionState == .connected else {
            throw CancellationError()
        }
    }

    private func fail(_ message: String, generation startedAt: Int) {
        guard startedAt == generation else { return }
        isFresh = false
        errorMessage = message
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, _ response: Any) throws -> Value {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: response))
    }

    private static func makeProviders(
        _ catalog: Catalog, settings: Enablement, authentication: Authentication
    ) throws -> [Provider] {
        let enabled = try settings.validatedValue()
        try authentication.validate()
        guard Set(catalog.providers.map(\.id)).count == catalog.providers.count,
              catalog.providers.allSatisfy({ !$0.id.isEmpty && !$0.displayName.isEmpty }) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return catalog.providers.filter(\.visible).map { entry in
            Provider(
                id: entry.id,
                name: entry.displayName,
                canBeDisabled: entry.canBeDisabled,
                supportsTestPrompt: entry.supportsTestPrompt == true,
                loginDocsURL: entry.loginDocsUrl.flatMap(Self.documentationURL),
                enabled: !entry.canBeDisabled || enabled[entry.id] == true,
                authentication: authentication.status(for: entry.id)
            )
        }
    }

    private static func documentationURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}

private extension ProviderManagementStore {
    struct Catalog: Decodable {
        let providers: [CatalogEntry]
    }

    struct CatalogEntry: Decodable {
        let id: String
        let displayName: String
        let visible: Bool
        let canBeDisabled: Bool
        // Older hosts omit this additive capability; omission never enables a test.
        // swiftlint:disable:next discouraged_optional_boolean
        let supportsTestPrompt: Bool?
        let loginDocsUrl: String?
    }

    enum EnablementCodingKeys: String, CodingKey {
        case path
        case value
    }

    enum TestResultCodingKeys: String, CodingKey {
        case reason
        case succeeded = "ok"
    }

    struct Enablement: Decodable {
        let path: String
        let value: [String: Bool]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: EnablementCodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            value = try container.decodeNil(forKey: .value) ? [:] : container.decode([String: Bool].self, forKey: .value)
        }

        func validatedValue() throws -> [String: Bool] {
            guard path == "providers.enabled" else { throw CocoaError(.coderReadCorrupt) }
            return value
        }
    }

    struct Authentication: Decodable {
        let providers: [AuthenticationEntry]

        func validate() throws {
            guard Set(providers.map(\.id)).count == providers.count, providers.allSatisfy({ !$0.id.isEmpty }) else {
                throw CocoaError(.coderReadCorrupt)
            }
        }

        func status(for id: String) -> ProviderAuthentication {
            let entry = providers.first { $0.id == id }
            return switch entry?.authenticated {
            case true: .signedIn
            case false: .signedOut
            case nil: .unknown
            }
        }
    }

    struct AuthenticationEntry: Decodable {
        let id: String
        // swiftlint:disable:next discouraged_optional_boolean
        let authenticated: Bool?
    }

    struct TestResult: Decodable {
        let succeeded: Bool
        let reason: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: TestResultCodingKeys.self)
            succeeded = try container.decode(Bool.self, forKey: .succeeded)
            reason = try container.decodeIfPresent(String.self, forKey: .reason)
        }

        var guidance: String {
            guard !succeeded else { return "Test passed. This provider answered a prompt on the host." }
            switch reason {
            case "auth-required": return "Sign in on the host computer, then refresh and test again."
            case "not-installed": return "Install this provider on the host computer, then refresh and test again."
            case "unsupported": return "This host does not support testing this provider."
            case "busy": return "The host is busy. Try testing again shortly."
            case "timeout": return "The test timed out. Check the provider on the host computer and try again."
            default: return "The test failed. Check the provider on the host computer and try again."
            }
        }
    }
}
