import Foundation

nonisolated struct InviteLink: Equatable, Sendable {
    enum Scope: String, Equatable, Sendable {
        case workspace
        case host
    }

    let scope: Scope
    let hosts: [String]
    let port: Int
    let fingerprint: String
    let tcAddress: String?
    let inviteId: String
    let secret: String

    static func isInviteURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "intent" && url.host?.lowercased() == "invite"
    }

    static func parse(_ url: URL) -> Self? {
        guard isInviteURL(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil,
              components.path.isEmpty || components.path == "/" else { return nil }
        let items = components.queryItems ?? []
        let names = ["v", "scope", "host", "port", "fp", "inviteId", "secret", "tc"]
        guard names.allSatisfy({ name in items.filter { $0.name == name }.count <= 1 }) else { return nil }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespaces).nonEmpty
        }
        let scopeText = value("scope") ?? Scope.workspace.rawValue
        guard value("v").map({ $0 == "1" }) ?? true,
              let scope = Scope(rawValue: scopeText),
              let portText = value("port"), portText.allSatisfy(\.isASCII), let port = Int(portText),
              (1...Int(UInt16.max)).contains(port),
              let fingerprint = value("fp"), (try? InvitedSyncKey.fingerprint(fingerprint)) != nil,
              let inviteId = value("inviteId"), let secret = value("secret") else { return nil }
        let rawHosts = (value("host") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let hosts = rawHosts.compactMap(SyncedBackendConnectionMerge.usableHost)
        guard hosts.count == rawHosts.count else { return nil }
        let tcAddress = value("tc")
        guard !hosts.isEmpty || tcAddress != nil else { return nil }
        return Self(
            scope: scope,
            hosts: hosts,
            port: port,
            fingerprint: fingerprint,
            tcAddress: tcAddress,
            inviteId: inviteId,
            secret: secret
        )
    }
}

extension InviteLink {
    var url: URL? {
        var components = URLComponents()
        components.scheme = "intent"
        components.host = "invite"
        var items = [URLQueryItem(name: "v", value: "1")]
        if scope == .host { items.append(URLQueryItem(name: "scope", value: scope.rawValue)) }
        if !hosts.isEmpty { items.append(URLQueryItem(name: "host", value: hosts.joined(separator: ","))) }
        items += [
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "fp", value: fingerprint),
            URLQueryItem(name: "inviteId", value: inviteId),
            URLQueryItem(name: "secret", value: secret)
        ]
        if let tcAddress { items.append(URLQueryItem(name: "tc", value: tcAddress)) }
        components.queryItems = items
        return components.url
    }
}

nonisolated private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
