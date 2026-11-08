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

    private enum Situation {
        case localNetworkDenied, offline, startupFailed, starting, indexing(DaemonStartupStatus.Progress?), finalizing, securing, reconnecting
    }

    private var situation: Situation {
        if case .unsatisfied(.localNetworkDenied) = networkStatus { return .localNetworkDenied }
        if network.isUnavailable { return .offline }
        switch startupState {
        case .failed: return .startupFailed
        case .starting(let status):
            switch status?.phase {
            case .indexing: return .indexing(status?.progress)
            case .finalizing: return .finalizing
            case .ready: return .securing
            case .failed: return .startupFailed
            case .preparing, nil: return .starting
            }
        case .unavailable, nil: return .reconnecting
        }
    }

    /// Full sentence for the expanded card and VoiceOver.
    var title: String {
        switch situation {
        case .localNetworkDenied: String(localized: "Local Network access needed · Read-only")
        case .offline: String(localized: "No network connection · Read-only")
        case .startupFailed: String(localized: "Startup failed · Read-only")
        case .starting: String(localized: "Desktop is starting… · Read-only")
        case .indexing(let progress?):
            String(localized: "Indexing notes (\(progress.completedNotes) of \(progress.totalNotes))… · Read-only")
        case .indexing(nil): String(localized: "Desktop is indexing notes… · Read-only")
        case .finalizing: String(localized: "Desktop is finishing startup… · Read-only")
        case .securing: String(localized: "Connecting securely… · Read-only")
        case .reconnecting:
            if let machineName { String(localized: "Reconnecting to \(machineName)… · Read-only") } else {
                String(localized: "Reconnecting… · Read-only")
            }
        }
    }

    /// A few words for the collapsed pill, short enough to clear the navigation bar's buttons.
    var shortTitle: String {
        switch situation {
        case .localNetworkDenied: String(localized: "Local Network off")
        case .offline: String(localized: "No network")
        case .startupFailed: String(localized: "Startup failed")
        case .starting: String(localized: "Desktop starting…")
        case .indexing(let progress?): String(localized: "Indexing \(progress.completedNotes)/\(progress.totalNotes)")
        case .indexing(nil): String(localized: "Indexing notes…")
        case .finalizing: String(localized: "Finishing startup…")
        case .securing: String(localized: "Connecting…")
        case .reconnecting: String(localized: "Reconnecting…")
        }
    }

    var guidance: String {
        if let guidance = network.guidance { return String(localized: guidance) }
        return String(localized: "You can keep reading. Changes are turned off until the connection comes back.")
    }
}

/// Floating, non-blocking pill shown while reconnection keeps trying. It tucks
/// under the status bar, above the navigation bar's title, without reserving
/// space; tapping it opens a card with guidance, certificate warnings, Retry and Back to Home.
struct ReadOnlyBanner: View {
    private enum Layout {
        static let collapsedMaximumWidth: CGFloat = 220
        static let expandedMaximumWidth: CGFloat = 360
        static let spacing: CGFloat = 6
        static let detailSpacing: CGFloat = 12
        static let horizontalPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 5
        static let detailPadding: CGFloat = 16
        static let expandedCornerRadius: CGFloat = 22
        /// Larger than half the pill's height; the shape clamps it into a capsule.
        static let capsuleCornerRadius: CGFloat = 100
        static let outerPadding: CGFloat = 8
        /// How far the pill rises into the status bar band, so it sits just under
        /// the Dynamic Island and above the navigation bar's title.
        static let statusBarTuck: CGFloat = 9
        static let minimumTop: CGFloat = 4
        static let actionHeight: CGFloat = 40
        static let actionCornerRadius: CGFloat = 12
        static let shadowOpacity: Double = 0.15
        static let shadowRadius: CGFloat = 8
        static let shadowYOffset: CGFloat = 2
    }

    @ScaledMetric(relativeTo: .caption) private var iconSize: CGFloat = 13
    @State private var isExpanded = false
    @State private var safeAreaTop: CGFloat = 0
    let message: ReadOnlyBannerMessage
    let mismatches: [HostCertMismatch]
    let onHome: () -> Void
    var onRetry: (() -> Void)?
    /// Reports the banner's frame in window coordinates so the hosting window
    /// passes every other touch through to the app below.
    var onInteractiveFrameChange: (CGRect) -> Void = { _ in }

    var body: some View {
        WidthCap(maxWidth: isExpanded ? Layout.expandedMaximumWidth : Layout.collapsedMaximumWidth) { content }
            .background(.regularMaterial, in: shape)
            .shadow(color: .black.opacity(Layout.shadowOpacity), radius: Layout.shadowRadius, y: Layout.shadowYOffset)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onInteractiveFrameChange($0) }
            .padding(.horizontal, Layout.outerPadding)
            .padding(.top, max(Layout.minimumTop, safeAreaTop - Layout.statusBarTuck))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(.container, edges: .top)
            .background {
                Color.clear
                    .ignoresSafeArea()
                    .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { safeAreaTop = $0 }
            }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Layout.detailSpacing) {
            HStack(spacing: Layout.spacing) {
                Button {
                    withAnimation(.snappy) { isExpanded.toggle() }
                } label: {
                    summary
                }
                .buttonStyle(IntentContentButtonStyle())
                .accessibilityLabel(message.title)
                .accessibilityIdentifier("read-only-banner")
                .accessibilityHint(isExpanded ? "Hides connection details." : "Shows connection details.")
                if canRetry, !isExpanded { inlineRetryButton }
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
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: isExpanded ? Layout.expandedCornerRadius : Layout.capsuleCornerRadius, style: .continuous)
    }

    private var canRetry: Bool { message.startupState == .failed && onRetry != nil }

    private var inlineRetryButton: some View {
        Button { onRetry?() } label: {
            Text("Retry")
                .interFont(Constants.Typography.subtextXXS.withFace(.semibold))
                .foregroundStyle(.tint)
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityHint("Tries to connect to the desktop again.")
        .accessibilityIdentifier("read-only-banner.retry")
    }

    private var summary: some View {
        HStack(spacing: Layout.spacing) {
            statusIcon
            Text(isExpanded ? message.title : message.shortTitle)
                .interFont(isExpanded ? Constants.Typography.bodyXSEmphasized : Constants.Typography.subtextXXS.withFace(.medium))
                .lineLimit(isExpanded ? nil : 1)
                .fixedSize(horizontal: false, vertical: isExpanded)
                .accessibilityIdentifier("read-only-banner.title")
            if isExpanded {
                Spacer(minLength: 0)
                Image(.chevronUp)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
    }

    @ViewBuilder private var statusIcon: some View {
        if message.networkStatus.isUnsatisfied || message.startupState == .failed {
            Image(.attentionCircleFill)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
        } else {
            ProgressView()
                .controlSize(.mini)
                .frame(width: iconSize, height: iconSize)
                .accessibilityHidden(true)
        }
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
            if canRetry {
                actionButton("Retry", hint: "Tries to connect to the desktop again.", identifier: "read-only-banner.retry") {
                    onRetry?()
                }
            }
            actionButton(
                "Back to Home",
                hint: "Return to your saved machines without forgetting this connection.",
                identifier: "read-only-banner.home",
                action: onHome
            )
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func actionButton(
        _ title: LocalizedStringKey,
        hint: LocalizedStringKey,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .interFont(Constants.Typography.bodyXSEmphasized)
                .frame(maxWidth: .infinity, minHeight: Layout.actionHeight)
                .background(.quaternary, in: .rect(cornerRadius: Layout.actionCornerRadius, style: .continuous))
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityHint(hint)
        .accessibilityIdentifier(identifier)
    }
}

/// Caps the proposed width but, unlike `frame(maxWidth:)`, takes its content's
/// size, so the collapsed pill hugs short text and truncates long text.
private struct WidthCap: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(proposal.width ?? maxWidth, maxWidth)
        return subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

extension NetworkAvailability.Status {
    var isUnsatisfied: Bool { ConnectionNetworkMessage(status: self).isUnavailable }
}
