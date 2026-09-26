import CoreText
import SwiftUI

/// The pairing paths PairingView offers, platform-filtered: visionOS exposes
/// no camera to third-party apps, so live QR scanning is not a viable path
/// there and is excluded from the options list.
enum PairingOption: Equatable {
    case manualEntry
    case qrScan
    case savedConnections

    /// Whether live camera QR scanning exists on this platform.
    static var platformSupportsCameraScanning: Bool {
        #if os(visionOS)
        false
        #else
        true
        #endif
    }

    static func available(
        showsSavedConnections: Bool,
        supportsCameraScanning: Bool = platformSupportsCameraScanning
    ) -> [Self] {
        var options: [Self] = []
        if supportsCameraScanning {
            options.append(.qrScan)
        }
        options.append(.manualEntry)
        if showsSavedConnections {
            options.append(.savedConnections)
        }
        return options
    }
}

struct PairingView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(\.colorScheme) var colorScheme
    @State private var showQRScanner = false
    @State private var showManualEntry = false
    @State private var showConnections = false
    @ScaledMetric(relativeTo: .title) private var headingCapHeight = PairingTextMetrics.headingCapHeight
    @ScaledMetric(relativeTo: .body) private var bodyCapHeight = PairingTextMetrics.bodyCapHeight
    @ScaledMetric(relativeTo: .body) private var bodyLineSpacing = PairingTextMetrics.bodyLineSpacing

    var body: some View {
        NavigationStack {
            pairingContent
                .toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $showQRScanner) { QRScannerView() }
                .sheet(isPresented: $showManualEntry) { ManualTokenEntryView() }
                .sheet(isPresented: $showConnections) { ConnectionsView() }
        }
        .preference(
            key: ConnectionBackdropPreference.self,
            value: showManualEntry ? ConnectionBackdropPreference.manualOpacity
                : (showConnections ? ConnectionBackdropPreference.savedOpacity : 0)
        )
    }

    private var pairingContent: some View {
        ZStack {
            Constants.Pairing.background(for: colorScheme).ignoresSafeArea()
            // Safe insets are required synchronously for the first layout, without a state feedback pass.
            // swiftlint:disable:next geometry_reader_usage
            GeometryReader { geometry in
                // Equal outer safe margins center on the full container, not the
                // asymmetric safe area. The same protected region gates scrolling.
                ViewThatFits(in: .vertical) {
                    pairingLayout
                    ScrollView { pairingLayout }
                }
                .padding(.vertical, Constants.Pairing.optionsHorizontalPadding)
                .padding(.top, max(0, geometry.safeAreaInsets.bottom - geometry.safeAreaInsets.top))
                .padding(.bottom, max(0, geometry.safeAreaInsets.top - geometry.safeAreaInsets.bottom))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var pairingLayout: some View {
        VStack(spacing: Constants.Pairing.contentSpacing) {
            pairingHeader
            pairingOptions
        }
        .frame(maxWidth: Constants.Pairing.maximumContentWidth)
        .padding(.horizontal, Constants.Pairing.optionsHorizontalPadding)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var pairingHeader: some View {
        PairingHeaderLayout(capHeights: [headingCapHeight, bodyCapHeight], spacing: Constants.Pairing.headerSpacing) {
            Text("Connect to Intent")
                .interFont(Constants.Typography.heading2)
                .tracking(Constants.Pairing.headingTracking)
                .foregroundStyle(Constants.Pairing.foreground(for: colorScheme))
                .multilineTextAlignment(.center)
            Text("Pair with your desktop app to manage workspaces and chat with agents.")
                .interFont(Constants.Typography.bodyS)
                .tracking(Constants.Pairing.bodyTracking)
                .lineSpacing(bodyLineSpacing)
                .foregroundStyle(Constants.Pairing.mutedForeground(for: colorScheme))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Constants.Pairing.descriptionHorizontalPadding)
    }

    private var pairingOptions: some View {
        let options = PairingOption.available(
            showsSavedConnections: coordinator.pairingShowsSavedConnections
        )
        return VStack(spacing: Constants.Pairing.optionsSpacing) {
            if options.contains(.qrScan) {
                PairingOptionButton(
                    icon: .connectQR,
                    title: "Scan QR Code",
                    subtitle: "Fastest way to connect",
                    isProminent: true,
                    colorScheme: colorScheme
                ) { showQRScanner = true }
            }
            if options.contains(.manualEntry) {
                PairingOptionButton(
                    icon: .connectManual,
                    title: "Manual Connection",
                    subtitle: "Enter IP, port, and token",
                    colorScheme: colorScheme
                ) { showManualEntry = true }
            }
            if options.contains(.savedConnections) {
                PairingOptionButton(
                    icon: .connectSaved,
                    title: "Saved Connections",
                    subtitle: "Reconnect to paired daemon",
                    colorScheme: colorScheme
                ) { showConnections = true }
            }
            visionPairingHint
        }
    }

    @ViewBuilder
    private var visionPairingHint: some View {
        #if os(visionOS)
        Text("Pair from your iPhone or Mac: open the intent://pair link shown in the Intent desktop app.")
            .interFont(Constants.Typography.subtextXXS)
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .multilineTextAlignment(.center)
        #endif
    }
}

/// Figma spaces the header from cap top to last baseline, not native line-box
/// edges. Measure real multiline baselines without clipping or fixing text height.
private struct PairingHeaderLayout: Layout {
    let capHeights: [CGFloat]
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let textProposal = ProposedViewSize(width: proposal.width, height: nil)
        var size = CGSize.zero
        for (subview, capHeight) in zip(subviews, capHeights) {
            let dimensions = subview.dimensions(in: textProposal)
            size.width = max(size.width, dimensions.width)
            size.height += dimensions[.lastTextBaseline] - dimensions[.firstTextBaseline] + capHeight
        }
        size.height += spacing * CGFloat(max(0, subviews.count - 1))
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let textProposal = ProposedViewSize(width: bounds.width, height: nil)
        var capTop = bounds.minY
        for (subview, capHeight) in zip(subviews, capHeights) {
            let dimensions = subview.dimensions(in: textProposal)
            let origin = capTop + capHeight - dimensions[.firstTextBaseline]
            subview.place(at: CGPoint(x: bounds.midX, y: origin), anchor: .top, proposal: textProposal)
            capTop += dimensions[.lastTextBaseline] - dimensions[.firstTextBaseline]
                + capHeight + spacing
        }
    }
}

private enum PairingTextMetrics {
    private static let heading = font(Constants.Typography.heading2)
    private static let body = font(Constants.Typography.bodyS)
    private static let bodyLineHeightRatio: CGFloat = 1.32 // Figma Connect description.
    private static let bodyLineHeight = CTFontGetAscent(body) + CTFontGetDescent(body) + CTFontGetLeading(body)
    static let headingCapHeight = CTFontGetCapHeight(heading)
    static let bodyCapHeight = CTFontGetCapHeight(body)
    static let bodyLineSpacing = max(0, Constants.Typography.bodyS.size * bodyLineHeightRatio - bodyLineHeight)
    // Inter Regular and Medium share vertical metrics. Native line boxes already
    // contribute this whitespace to the title/subtitle gap between visible caps.
    static let bodyNativeLeading = bodyLineHeight - bodyCapHeight

    private static func font(_ style: Constants.Typography.Style) -> CTFont {
        CTFontCreateWithName(style.face.rawValue as CFString, style.size, nil)
    }
}

struct PairingOptionButton: View {
    let icon: ImageResource
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    var isProminent = false
    let colorScheme: ColorScheme
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var nativeLeading = PairingTextMetrics.bodyNativeLeading

    var body: some View {
        Button(action: action) {
            HStack(spacing: Constants.Pairing.optionSpacing) {
                iconTile

                VStack(alignment: .leading, spacing: max(0, Constants.Pairing.optionTextSpacing - nativeLeading)) {
                    Text(title)
                        .interFont(Constants.Typography.bodySEmphasized)
                        .tracking(Constants.Pairing.optionTitleTracking)
                        .foregroundStyle(Constants.Pairing.foreground(for: colorScheme))
                    Text(subtitle)
                        .interFont(Constants.Typography.bodyS)
                        .tracking(Constants.Pairing.bodyTracking)
                        .foregroundStyle(Constants.Pairing.mutedForeground(for: colorScheme))
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Constants.Pairing.optionPadding)
            .padding(.vertical, isProminent ? Constants.Pairing.optionPadding : 0)
            .background(isProminent ? Constants.Pairing.surface(for: colorScheme) : .clear)
            .clipShape(.rect(cornerRadius: Constants.Pairing.optionCornerRadius))
            .contentShape(.rect(cornerRadius: Constants.Pairing.optionCornerRadius))
        }
        .buttonStyle(.plain)
        .visionCardRowButton(cornerRadius: Constants.Pairing.optionCornerRadius)
    }

    private var iconTile: some View {
        Image(icon)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: Constants.Pairing.glyphSize, height: Constants.Pairing.glyphSize)
            .foregroundStyle(isProminent ? Constants.Pairing.onAccent : Constants.Pairing.foreground(for: colorScheme))
            .frame(width: Constants.Pairing.iconTileSize, height: Constants.Pairing.iconTileSize)
            .background(isProminent ? Constants.Pairing.accent : Constants.Pairing.surface(for: colorScheme))
            .clipShape(.rect(cornerRadius: Constants.Pairing.iconTileCornerRadius))
            .accessibilityHidden(true)
    }
}
