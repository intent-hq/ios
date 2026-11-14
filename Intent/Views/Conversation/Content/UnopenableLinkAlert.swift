import SwiftUI

/// A tapped link the app can't open. It is shown in an alert with the link
/// target and a Copy Link action, so a link tap never silently does nothing.
nonisolated struct UnopenableLink: Equatable {
    enum Reason: Equatable {
        /// No scheme (a relative or absolute path), a `file://` link, or an
        /// app-internal scheme: iOS has nothing that opens it.
        case unsupportedLocation
        /// An `intent://` link that is not a file, note, task, pairing or invite link.
        /// iOS would route it back to the app, which ignores it.
        case unsupportedIntentLink
        /// The in-app browser could not open a local server link.
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

    /// Why iOS can't open `url`, or nil when it can be handed to iOS.
    /// Callers route workspace file and note links before asking.
    static func reason(for url: URL) -> Reason? {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return .unsupportedLocation }
        // A one-letter scheme is a Windows drive path such as `C:/Users/…`.
        if scheme.count == 1 || Self.unsupportedSchemes.contains(scheme) { return .unsupportedLocation }
        if scheme == "intent" {
            // Pairing and invite links are the only `intent://` links the app
            // acts on when iOS hands them back (AppCoordinator.handleIncomingURL).
            return ["pair", "invite"].contains(url.host?.lowercased()) ? nil : .unsupportedIntentLink
        }
        return nil
    }

    private static let unsupportedSchemes: Set<String> = ["file", "workspace-asset"]
}

extension View {
    /// Presents `link` in an alert with Copy Link and OK actions.
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
