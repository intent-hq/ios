#if DEBUG
import Foundation

enum DemoSharingFixtures {
    private static let fingerprintBytes = 32
    private static let fingerprint = String(repeating: "ab", count: fingerprintBytes)
    private static let day: TimeInterval = 86_400
    private static let expiryDays: Double = 7
    private static let expiry = expiryDays * day
    private static var nextInvite = 1

    static func response(for method: String, params: [String: Any]) -> Any? {
        guard method == "workspace.invite.create" else { return nil }
        let id = "demo-invite-\(nextInvite)"
        nextInvite += 1
        let formatter = ISO8601DateFormatter()
        let pinLogin = params["pinLogin"] as? String
        var invite: [String: Any] = [
            "id": id, "workspaceId": params["workspaceId"] as? String ?? "demo",
            "createdAt": formatter.string(from: Date()),
            "expiresAt": formatter.string(from: Date().addingTimeInterval(expiry)),
            "reusable": pinLogin == nil, "redemptionCount": 0
        ]
        if let pinLogin { invite["pinLogin"] = pinLogin }
        let url = "intent://invite?v=1&port=5181&fp=\(fingerprint)&inviteId=\(id)&secret=demo&tc=tc1-demo"
        return ["invite": invite, "url": url, "secret": "demo"]
    }
}
#endif
