#if os(iOS)
import Foundation

/// `device` in the relay contract. Nil fields are left out, so the same type
/// serves the full registration body and a partial PATCH.
nonisolated struct RelayDeviceInfo: Codable, Equatable, Sendable {
    nonisolated struct Preferences: Codable, Equatable, Sendable {
        var liveActivity: Bool
    }

    var bundleId: String?
    var apsEnvironment: String?
    var appVersion: String?
    var osVersion: String?
    var pushToken: String?
    var pushToStartToken: String?
    var preferences: Preferences?
}

nonisolated struct RelaySnapshot: Decodable, Sendable {
    let contentState: AgentActivityAttributes.ContentState
    let liveActivityActive: Bool
}

nonisolated enum RelayClientError: Error, Equatable {
    case status(Int, String)
    case invalidResponse
}

/// Device-side calls to the push relay. Every request carries a fresh proof.
nonisolated struct RelayClient: Sendable {
    nonisolated struct Registration: Decodable, Equatable, Sendable {
        let deviceId: String
        let daemonId: String
    }

    let baseURL: URL
    let signer: any RelaySigner
    var session: URLSession = .shared
    var now: @Sendable () -> Date = { .now }

    private var deviceId: String { signer.deviceId }

    nonisolated private struct RegistrationBody: Encodable {
        let linkToken: String
        let connectionId: String
        let publicKey: String
        let device: RelayDeviceInfo
    }

    nonisolated private struct DeviceBody: Encodable {
        let device: RelayDeviceInfo
    }

    /// Encodes `pushToken` as an explicit null when the activity ended.
    nonisolated private struct ActivityTokenBody: Encodable {
        enum CodingKeys: String, CodingKey { case pushToken }

        let pushToken: String?

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(pushToken, forKey: .pushToken)
        }
    }

    func register(linkToken: String, connectionId: UUID, device: RelayDeviceInfo) async throws -> Registration {
        let body = RegistrationBody(linkToken: linkToken, connectionId: connectionId.uuidString, publicKey: signer.publicKey, device: device)
        let data = try await send("POST", "/v1/devices", body: try JSONEncoder().encode(body))
        return try JSONDecoder().decode(Registration.self, from: data)
    }

    func updateDevice(_ device: RelayDeviceInfo) async throws {
        _ = try await send("PATCH", "/v1/devices/\(deviceId)", body: try JSONEncoder().encode(DeviceBody(device: device)))
    }

    /// `nil` tells the relay the activity ended.
    func setLiveActivityToken(_ token: String?) async throws {
        _ = try await send("PUT", "/v1/devices/\(deviceId)/live-activity", body: try JSONEncoder().encode(ActivityTokenBody(pushToken: token)))
    }

    func unlink(daemonId: String) async throws {
        _ = try await send("DELETE", "/v1/devices/\(deviceId)/links/\(daemonId)", body: nil)
    }

    func snapshot() async throws -> RelaySnapshot {
        let data = try await send("GET", "/v1/devices/\(deviceId)/snapshot", body: nil)
        return try JSONDecoder().decode(RelaySnapshot.self, from: data)
    }

    private func send(_ method: String, _ path: String, body: Data?) async throws -> Data {
        let url = baseURL.appending(path: path)
        let signedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? path
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let proof = try RelayProof.make(signer: signer, method: method, path: signedPath, body: body ?? Data(), now: now())
        request.setValue("\(RelayProof.scheme) \(proof)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw RelayClientError.status(http.statusCode, String(bytes: data, encoding: .utf8) ?? "")
        }
        return data
    }
}
#endif
