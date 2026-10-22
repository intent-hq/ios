import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    var presentedAsSheet = false
    var contentColorScheme: ColorScheme?
    var isEmbedded = false
    var onCollapse: (() -> Void)?
    var onScanQR: (() -> Void)?
    var onManualPairing: (() -> Void)?

    var body: some View {
        NavigationStack {
            SettingsContent(
                presentedAsSheet: presentedAsSheet,
                isEmbedded: isEmbedded,
                onCollapse: onCollapse,
                onScanQR: onScanQR,
                onManualPairing: onManualPairing
            )
                .environment(\.colorScheme, contentColorScheme ?? colorScheme)
                .modifier(IPadNavigationVisibility(isEnabled: isEmbedded))
        }
        #if os(iOS)
        .background {
            if presentedAsSheet {
                SettingsStatusBarCapture()
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        #endif
    }
}

#if os(iOS)
private struct SettingsStatusBarCapture: UIViewControllerRepresentable {
    func makeUIViewController(context _: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context _: Context) {
        controller.captureStatusBar()
    }

    final class Controller: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            captureStatusBar()
        }

        func captureStatusBar() {
            var presentation: UIViewController = self
            while let parent = presentation.parent { presentation = parent }
            guard presentation.presentingViewController != nil else { return }
            // Non-fullscreen presentations otherwise keep the presenting screen's status-bar style.
            presentation.modalPresentationCapturesStatusBarAppearance = true
            presentation.setNeedsStatusBarAppearanceUpdate()
        }
    }
}
#endif

private struct SettingsContent: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(BackendSession.self) var session
    @Environment(\.colorScheme) var colorScheme
    @State private var showLogOffConfirmation = false
    @ScaledMetric(relativeTo: .callout) private var iconSize = SettingsStyle.iconWidth
    var presentedAsSheet = false
    var isEmbedded = false
    var onCollapse: (() -> Void)?
    var onScanQR: (() -> Void)?
    var onManualPairing: (() -> Void)?

    var body: some View {
        Group {
            if isEmbedded { embeddedSurface } else { settingsSurface }
        }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showLogOffConfirmation) {
                LogOffConfirmationSheet { coordinator.onLogOff() }
                    .environment(\.colorScheme, colorScheme)
            }
    }

    private func collapseSidebar() { onCollapse?() }

    private var embeddedSurface: some View {
        VStack(spacing: 0) {
            IPadSidebarHeader(onCollapse: collapseSidebar) {
                IPadSidebarTitle(title: "Settings")
            } actions: {}
            ScrollView {
                VStack(alignment: .leading, spacing: IPadSidebarStyle.settingsSpacing) {
                    settingsSections
                }
                .padding(.horizontal, IPadSidebarStyle.inset)
                .padding(.bottom, IPadSidebarStyle.inset)
            }
            .accessibilityIdentifier("settings.scroll")
        }
        .buttonStyle(IntentContentButtonStyle())
        .foregroundStyle(SettingsStyle.foreground(for: colorScheme))
        .background(IPadSidebarStyle.background(for: colorScheme))
    }

    @ViewBuilder private var settingsSections: some View {
        if !session.connection.certMismatches.isEmpty {
            CertMismatchListView(mismatches: session.connection.certMismatches)
        }
        SettingsPairingSection(onScanQR: onScanQR, onManualPairing: onManualPairing)
        SettingsAgentSection()
        if isEmbedded {
            SettingsSection(title: "SETTINGS") { SettingsSupportSection() }
        } else {
            SettingsSupportSection()
        }
        logOffButton
    }

    private var settingsSurface: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
                SettingsHeader(onClose: coordinator.onSettingsBack)
                    .padding(.bottom, SettingsStyle.headingSpacing - SettingsStyle.sectionSpacing)
                settingsSections
            }
            .padding(SettingsStyle.contentMargin)
            .frame(maxWidth: SettingsStyle.maximumContentWidth)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("settings.scroll")
        .buttonStyle(IntentContentButtonStyle())
        .foregroundStyle(SettingsStyle.foreground(for: colorScheme))
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: SettingsStyle.surfaceRadius,
            topTrailingRadius: SettingsStyle.surfaceRadius
        ))
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: SettingsStyle.surfaceRadius,
                topTrailingRadius: SettingsStyle.surfaceRadius
            )
            .fill(SettingsStyle.surface(for: colorScheme))
            .ignoresSafeArea(edges: .bottom)
        }
        // Keep the real system status bar and its light/dark contrast. Do not
        // draw the status bar or force the rest of Settings into dark mode.
        .background(outerBackground.ignoresSafeArea())
    }

    private var outerBackground: Color {
        presentedAsSheet ? .clear : (colorScheme == .dark ? SettingsStyle.charcoal : SettingsStyle.lightChrome)
    }

    private var logOffButton: some View {
        Button { showLogOffConfirmation = true } label: {
            Label {
                Text("Disconnect").interFont(Constants.Typography.bodySEmphasized)
            } icon: {
                Image(.logout)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
            }
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, SettingsStyle.rowVerticalPadding)
                .frame(maxWidth: .infinity, minHeight: SettingsStyle.rowHeight)
                .foregroundStyle(SettingsStyle.lightForeground)
                .background(SettingsStyle.accent, in: .rect(cornerRadius: SettingsStyle.cardRadius))
                .contentShape(.rect(cornerRadius: SettingsStyle.cardRadius))
        }
    }
}

#Preview("Settings") {
    let session = BackendSessionRegistry.shared.makePairingSession()
    SettingsView()
        .environment(session)
        .environment(session.makeCoordinator())
}

#Preview("Settings - Dark") {
    let session = BackendSessionRegistry.shared.makePairingSession()
    SettingsView()
        .environment(session)
        .environment(session.makeCoordinator())
        .preferredColorScheme(.dark)
}

struct IPadSettingsSidebar: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.isIPadPaneVisible) private var isPaneVisible
    let onCollapse: () -> Void
    let onScanQR: () -> Void
    let onManualPairing: () -> Void

    var body: some View {
        ZStack {
            RetainedIPadPane(isVisible: coordinator.iPadNavigation.pairing == nil) {
                SettingsView(
                    isEmbedded: true,
                    onCollapse: onCollapse,
                    onScanQR: onScanQR,
                    onManualPairing: onManualPairing
                )
            }
            if isPaneVisible, let mode = coordinator.iPadNavigation.pairing {
                IPadPairingSidebar(title: "Settings", mode: mode, onCollapse: onCollapse)
            }
        }
    }
}
