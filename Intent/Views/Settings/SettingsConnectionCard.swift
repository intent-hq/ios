import SwiftUI

/// A presentation-only card, also usable for the saved-connections list.
/// A nil status represents a saved connection that is not this window's backend.
struct SettingsConnectionCard: View {
    let name: String
    let address: String
    let status: ConnectionState?

    var body: some View {
        SavedConnectionCard(name: name, address: address, status: status, textSpacing: SettingsStyle.textSpacing)
    }
}
