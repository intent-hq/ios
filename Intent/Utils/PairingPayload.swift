import Foundation

struct PairingPayload: Equatable {
    let hosts: [String]
    let port: Int
    let token: String
    let certFingerprint: String?
    let tcAddress: String?

    static func parse(_ code: String) -> Self? {
        guard let components = URLComponents(string: code),
              components.scheme == "intent",
              components.host == "pair",
              let items = components.queryItems,
              let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty,
              let portStr = items.first(where: { $0.name == "port" })?.value,
              let port = Int(portStr) else {
            return nil
        }

        let sensitive = ["token", "host", "port", "fp", "certFingerprint", "tc", "v"]
        guard sensitive.allSatisfy({ name in items.filter { $0.name == name }.count <= 1 }),
              InvitedSyncRecord.validPort(Double(port)),
              items.first(where: { $0.name == "v" }).map({ $0.value == "1" }) ?? true,
              components.user == nil, components.password == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return nil }
        let hostStr = items.first { $0.name == "host" }?.value ?? ""
        let rawHosts = hostStr.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let hosts = rawHosts.compactMap(SyncedBackendConnectionMerge.usableHost)
        guard hostStr.isEmpty || hosts.count == rawHosts.count else { return nil }

        let fingerprint = [
            items.first { $0.name == "fp" }?.value,
            items.first { $0.name == "certFingerprint" }?.value
        ]
        .compactMap { $0 }
        .first { !$0.isEmpty }

        let tcAddress = items.first { $0.name == "tc" }?.value
            .flatMap { $0.isEmpty ? nil : $0 }

        guard !hosts.isEmpty || tcAddress != nil else { return nil }

        return Self(
            hosts: hosts,
            port: port,
            token: token,
            certFingerprint: fingerprint,
            tcAddress: tcAddress
        )
    }
}
