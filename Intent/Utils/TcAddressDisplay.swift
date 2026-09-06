import Foundation

/// Display-only shortening of tailcat (`tc-…`) addresses: the first 10
/// characters followed by a single ellipsis when the address is longer than
/// 10 characters, the address unchanged otherwise. Never applied to stored
/// values or pairing payloads — callers keep the full address for
/// accessibility labels.
enum TcAddressDisplay {
    static let prefixLength = 10

    static func truncated(_ address: String) -> String {
        guard address.count > prefixLength else { return address }
        return String(address.prefix(prefixLength)) + "\u{2026}"
    }
}
