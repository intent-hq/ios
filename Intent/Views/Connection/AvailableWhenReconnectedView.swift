import SwiftUI

/// Shown instead of a loading state or an error when the app has no copy of
/// this content and the Mac connection is lost. The owning screen reloads by
/// itself on reconnect; there is nothing to retry here.
struct AvailableWhenReconnectedView: View {
    /// Inline row for embedded sections; a full empty state otherwise.
    var isCompact = false

    var body: some View {
        if isCompact {
            Text("Available when reconnected")
                .interFont(Constants.Typography.bodyS)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("read-only.unavailable")
        } else {
            fullState
        }
    }

    private var fullState: some View {
        ContentUnavailableView {
            Label("Available when reconnected", systemImage: "wifi.exclamationmark")
                .interFont(Constants.Typography.bodySEmphasized)
        } description: {
            Text("This wasn't loaded before the connection dropped.")
                .interFont(Constants.Typography.bodyXS)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("read-only.unavailable")
    }
}

extension View {
    /// Replaces this content with `AvailableWhenReconnectedView` while the
    /// connection is lost and `isMissing` says the content was never loaded.
    func availableWhenReconnected(isMissing: Bool, isCompact: Bool = false) -> some View {
        modifier(AvailableWhenReconnected(isMissing: isMissing, isCompact: isCompact))
    }
}

private struct AvailableWhenReconnected: ViewModifier {
    @Environment(\.isRemoteReadOnly) private var isReadOnly
    let isMissing: Bool
    let isCompact: Bool

    func body(content: Content) -> some View {
        if isReadOnly, isMissing {
            AvailableWhenReconnectedView(isCompact: isCompact)
        } else {
            content
        }
    }
}
