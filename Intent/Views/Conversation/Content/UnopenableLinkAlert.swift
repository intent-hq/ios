import SwiftUI

nonisolated struct UnopenableLink: Equatable {
    enum Reason: Equatable {
        case unsupportedLocation
        case unsupportedIntentLink
        case browserFailed(String)
    }

    static let title = "Can't Open Link"

    let target: String
    let reason: Reason

    init(url: URL, reason: Reason) {
        self.target = url.absoluteString
        self.reason = reason
    }

    var message: String {
        switch reason {
        case .unsupportedLocation, .unsupportedIntentLink:
            "This link can't be opened on this device.\n\n\(target)"
        case .browserFailed(let detail):
            "The in-app browser couldn't open this link. \(detail)\n\n\(target)"
        }
    }

    static func reason(for url: URL) -> Reason? {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return .unsupportedLocation }
        if scheme.count == 1 || Self.unsupportedSchemes.contains(scheme) { return .unsupportedLocation }
        if scheme == "intent" {
            return ["pair", "invite"].contains(url.host?.lowercased()) ? nil : .unsupportedIntentLink
        }
        return nil
    }

    private static let unsupportedSchemes: Set<String> = ["file", "workspace-asset"]
}

extension View {
    func unopenableLinkAlert(_ link: Binding<UnopenableLink?>) -> some View {
        alert(
            UnopenableLink.title,
            isPresented: Binding(get: { link.wrappedValue != nil }, set: { if !$0 { link.wrappedValue = nil } }),
            presenting: link.wrappedValue
        ) { item in
            Button("Copy Link") {
                UIPasteboard.general.string = item.target
                HapticManager.notification(.success)
            }
            Button("OK", role: .cancel) {}
        } message: { item in
            Text(item.message)
        }
    }
}
