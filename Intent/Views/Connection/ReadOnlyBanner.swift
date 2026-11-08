import Network
import SwiftUI

/// Copy for the read-only banner. It follows `ConnectionNetworkMessage` so a
/// phone-side problem names its fix instead of blaming the Mac.
struct ReadOnlyBannerMessage {
    let networkStatus: NetworkAvailability.Status
    let machineName: String?

    private var network: ConnectionNetworkMessage { ConnectionNetworkMessage(status: networkStatus) }

    var title: String {
        if case .unsatisfied(.localNetworkDenied) = networkStatus {
            return String(localized: "Local Network access needed · Read-only")
        }
        if network.isUnavailable { return String(localized: "No network connection · Read-only") }
        if let machineName { return String(localized: "Reconnecting to \(machineName)… · Read-only") }
        return String(localized: "Reconnecting… · Read-only")
    }

    var guidance: String {
        if let guidance = network.guidance { return String(localized: guidance) }
        return String(localized: "You can keep reading. Changes are turned off until the connection comes back.")
    }
}

/// Slim, non-blocking banner shown while reconnection keeps trying. Tapping it
/// reveals guidance, per-address certificate warnings and Back to Home.
struct ReadOnlyBanner: View {
    private enum Layout {
        static let maximumWidth: CGFloat = 480
        static let spacing: CGFloat = 8
        static let detailSpacing: CGFloat = 12
        static let horizontalPadding: CGFloat = 14
        static let verticalPadding: CGFloat = 8
        static let detailPadding: CGFloat = 16
        static let cornerRadius: CGFloat = 18
        static let outerPadding: CGFloat = 8
        static let actionHeight: CGFloat = 40
    }

    @ScaledMetric(relativeTo: .subheadline) private var iconSize: CGFloat = 16
    @State private var isExpanded = false
    let message: ReadOnlyBannerMessage
    let mismatches: [HostCertMismatch]
    let onHome: () -> Void
    /// Reports the banner's frame in window coordinates so the hosting window
    /// passes every other touch through to the app below.
    var onInteractiveFrameChange: (CGRect) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.detailSpacing) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                summary
            }
            .buttonStyle(IntentContentButtonStyle())
            .accessibilityIdentifier("read-only-banner")
            .accessibilityHint(isExpanded ? "Hides connection details." : "Shows connection details.")
            if isExpanded { details }
        }
        .padding(.horizontal, isExpanded ? Layout.detailPadding : Layout.horizontalPadding)
        .padding(.vertical, isExpanded ? Layout.detailPadding : Layout.verticalPadding)
        .background(.regularMaterial, in: .rect(cornerRadius: Layout.cornerRadius))
        .frame(maxWidth: Layout.maximumWidth)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onInteractiveFrameChange($0) }
        .padding(.horizontal, Layout.outerPadding)
        .padding(.top, Layout.outerPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var summary: some View {
        HStack(spacing: Layout.spacing) {
            if message.networkStatus.isUnsatisfied {
                Image(.attentionCircleFill)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            }
            Text(message.title)
                .interFont(Constants.Typography.bodyXSEmphasized)
                .lineLimit(isExpanded ? nil : 1)
                .accessibilityIdentifier("read-only-banner.title")
            Spacer(minLength: 0)
            Image(isExpanded ? .chevronUp : .chevronDown)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Layout.detailSpacing) {
            Text(message.guidance)
                .interFont(Constants.Typography.bodyXS)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("read-only-banner.guidance")
            if !mismatches.isEmpty {
                CertMismatchListView(mismatches: mismatches)
            }
            Button(action: onHome) {
                Text("Back to Home")
                    .interFont(Constants.Typography.bodyXSEmphasized)
                    .frame(maxWidth: .infinity, minHeight: Layout.actionHeight)
                    .background(.quaternary, in: .rect(cornerRadius: Layout.cornerRadius / 2))
            }
            .buttonStyle(IntentContentButtonStyle())
            .accessibilityHint("Return to your saved machines without forgetting this connection.")
            .accessibilityIdentifier("read-only-banner.home")
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

extension View {
    /// Reserves the collapsed banner's space at the top of the window so the
    /// banner never covers navigation (Back, titles, page actions).
    func readOnlyBannerInset(_ isPresented: Bool) -> some View {
        modifier(ReadOnlyBannerInset(isPresented: isPresented))
    }
}

enum ReadOnlyBannerMetrics {
    /// Collapsed banner: one line plus its padding, before Dynamic Type scaling.
    static let collapsedHeight: CGFloat = 46
}

private struct ReadOnlyBannerInset: ViewModifier {
    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = ReadOnlyBannerMetrics.collapsedHeight
    let isPresented: Bool

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if isPresented {
                Color.clear.frame(height: height).accessibilityHidden(true)
            }
        }
    }
}

extension NetworkAvailability.Status {
    var isUnsatisfied: Bool { ConnectionNetworkMessage(status: self).isUnavailable }
}
