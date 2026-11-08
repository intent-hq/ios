import Network
import SwiftUI

/// Copy for the read-only banner. It follows `ConnectionNetworkMessage` so a
/// phone-side problem names its fix instead of blaming the Mac.
struct ReadOnlyBannerMessage {
    let networkStatus: NetworkAvailability.Status
    let machineName: String?
    /// The desktop's startup phase while it is still starting up (R1.7).
    var startupState: DaemonStartupState?

    private var network: ConnectionNetworkMessage { ConnectionNetworkMessage(status: networkStatus) }

    var title: String {
        if case .unsatisfied(.localNetworkDenied) = networkStatus {
            return String(localized: "Local Network access needed · Read-only")
        }
        if network.isUnavailable { return String(localized: "No network connection · Read-only") }
        if let startup = startupTitle { return startup }
        if let machineName { return String(localized: "Reconnecting to \(machineName)… · Read-only") }
        return String(localized: "Reconnecting… · Read-only")
    }

    /// Phase-specific one-liners; nil falls back to the generic reconnecting copy.
    private var startupTitle: String? {
        switch startupState {
        case .failed: String(localized: "Startup failed · Read-only")
        case .starting(let status):
            switch status?.phase {
            case .indexing: indexingTitle(status?.progress)
            case .finalizing: String(localized: "Desktop is finishing startup… · Read-only")
            case .ready: String(localized: "Connecting securely… · Read-only")
            case .failed: String(localized: "Startup failed · Read-only")
            case .preparing, nil: String(localized: "Desktop is starting… · Read-only")
            }
        case .unavailable, nil: nil
        }
    }

    private func indexingTitle(_ progress: DaemonStartupStatus.Progress?) -> String {
        guard let progress else { return String(localized: "Desktop is indexing notes… · Read-only") }
        return String(localized: "Indexing notes (\(progress.completedNotes) of \(progress.totalNotes))… · Read-only")
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
        static let retryHeight: CGFloat = 28
    }

    @ScaledMetric(relativeTo: .subheadline) private var iconSize: CGFloat = 16
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isExpanded = false
    let message: ReadOnlyBannerMessage
    let mismatches: [HostCertMismatch]
    let onHome: () -> Void
    var onRetry: (() -> Void)?
    /// Reports the banner's frame in window coordinates so the hosting window
    /// passes every other touch through to the app below.
    var onInteractiveFrameChange: (CGRect) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.detailSpacing) {
            HStack(spacing: Layout.spacing) {
                Button {
                    withAnimation(.snappy) { isExpanded.toggle() }
                } label: {
                    summary
                }
                .buttonStyle(IntentContentButtonStyle())
                .accessibilityIdentifier("read-only-banner")
                .accessibilityHint(isExpanded ? "Hides connection details." : "Shows connection details.")
                if showsInlineRetry { retryButton }
            }
            if isExpanded {
                // Large type can outgrow the screen; the details then scroll.
                ViewThatFits(in: .vertical) {
                    details
                    ScrollView { details }.scrollBounceBehavior(.basedOnSize)
                }
            }
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

    private var canRetry: Bool { message.startupState == .failed && onRetry != nil }

    /// Beside the title only when it fits; otherwise Retry joins the details.
    private var showsInlineRetry: Bool { canRetry && !isExpanded && !dynamicTypeSize.isAccessibilitySize }

    private var retryButton: some View {
        Button { onRetry?() } label: {
            Text("Retry")
                .interFont(Constants.Typography.bodyXSEmphasized)
                .padding(.horizontal, Layout.spacing)
                .frame(maxWidth: showsInlineRetry ? nil : .infinity, minHeight: showsInlineRetry ? Layout.retryHeight : Layout.actionHeight)
                .background(.quaternary, in: .rect(cornerRadius: Layout.cornerRadius / 2))
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityHint("Tries to connect to the desktop again.")
        .accessibilityIdentifier("read-only-banner.retry")
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
            if let startupState = message.startupState {
                DaemonStartupProgressView(state: startupState)
            } else {
                Text(message.guidance)
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("read-only-banner.guidance")
            }
            if !mismatches.isEmpty {
                CertMismatchListView(mismatches: mismatches)
            }
            if canRetry, !showsInlineRetry { retryButton }
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

enum ReadOnlyBannerMetrics {
    /// Collapsed banner (one line plus its padding) before Dynamic Type scaling;
    /// the presenter reserves this much safe area at the top of the window.
    static let collapsedHeight: CGFloat = 46
}

extension NetworkAvailability.Status {
    var isUnsatisfied: Bool { ConnectionNetworkMessage(status: self).isUnavailable }
}
