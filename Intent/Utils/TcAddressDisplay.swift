import Foundation

enum TcAddressDisplay {
    static let prefixLength = 10

    static func truncated(_ address: String) -> String {
        guard address.count > prefixLength else { return address }
        return String(address.prefix(prefixLength)) + "\u{2026}"
    }
}
