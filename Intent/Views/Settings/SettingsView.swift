import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    var presentedAsSheet = false
    var contentColorScheme: ColorScheme?

    var body: some View {
        NavigationStack {
            SettingsContent(presentedAsSheet: presentedAsSheet)
                .environment(\.colorScheme, contentColorScheme ?? colorScheme)
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
    @AppStorage("appThemePreference") private var themePreference: String = "system"
    @State private var showLogOffConfirmation = false
    @ScaledMetric(relativeTo: .callout) private var iconSize = SettingsStyle.iconWidth
    var presentedAsSheet = false

    var body: some View {
        settingsSurface
            .onAppear { coordinator.refreshSyncedBackends() }
            .refreshable { coordinator.refreshSyncedBackends() }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showLogOffConfirmation) {
                LogOffConfirmationSheet { coordinator.onLogOff() }
                    .environment(\.colorScheme, colorScheme)
            }
    }

    private var settingsSurface: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
                SettingsHeader(onClose: coordinator.onSettingsBack)
                    .padding(.bottom, SettingsStyle.headingSpacing - SettingsStyle.sectionSpacing)
                SettingsSection(title: "APPEARANCE") {
                    SettingsAppearanceSelector(selection: $themePreference)
                }
                .padding(.bottom, SettingsStyle.appearanceBottomSpacing)
                SettingsConnectionsSection(
                    connections: coordinator.savedConnections,
                    windowConnectionID: coordinator.windowConnectionID,
                    status: session.connection.connectionState,
                    mismatches: session.connection.certMismatches,
                    onSelect: selectConnection
                )
                SettingsPairingSection()
                SettingsSupportSection()
                logOffButton
            }
            .padding(SettingsStyle.contentMargin)
            .frame(maxWidth: SettingsStyle.maximumContentWidth)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("settings.scroll")
        .buttonStyle(.plain)
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

    private func selectConnection(_ id: UUID) {
        if id == coordinator.windowConnectionID {
            coordinator.onSettingsBack()
        } else {
            coordinator.onSwitchConnection(id: id)
        }
    }

    private var logOffButton: some View {
        Button { showLogOffConfirmation = true } label: {
            Label {
                Text("Log Off").interFont(Constants.Typography.bodySEmphasized)
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
