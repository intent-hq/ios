import SwiftUI

struct IPadNavigationRail: View {
    let section: IPadSidebarSection
    let isSidebarVisible: Bool
    let canUseAssistant: Bool
    let onSelect: (IPadSidebarSection) -> Void
    let onExpand: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appThemePreference") private var themePreference = "system"

    var body: some View {
        ScrollView {
            VStack(spacing: IPadShellLayout.railSpacing) {
                if !isSidebarVisible {
                    railButton(asset: .collapseLeft, label: "Show sidebar", identifier: "ipad.sidebar.expand", action: onExpand)
                }
                destination(.assistant, asset: .intentDandelion, label: "Assistant")
                    .disabled(!canUseAssistant)
                destination(.workspaces, asset: .agents, label: "Workspaces")
                destination(.connections, asset: .connectionLaptop, label: "Connections")
                railButton(asset: appearanceIcon, label: "Appearance", identifier: "ipad.rail.appearance") {
                    themePreference = ["light": "dark", "dark": "system"][themePreference] ?? "light"
                }
                .accessibilityValue(appearanceTitle)
                .accessibilityHint("Changes appearance")
                destination(.settings, asset: .settings2, label: "Settings")
            }
            .padding(.top, IPadShellLayout.railTopInset)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: IPadShellLayout.railWidth)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Main navigation")
        .accessibilityIdentifier("ipad.rail")
    }

    private func destination(_ destination: IPadSidebarSection, asset: ImageResource, label: String) -> some View {
        railButton(
            asset: asset,
            label: label,
            identifier: "ipad.rail.\(destination.rawValue)",
            isSelected: section == destination
        ) {
            onSelect(destination)
        }
    }

    private func railButton(
        asset: ImageResource,
        label: String,
        identifier: String,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(asset)
                .resizable()
                .scaledToFit()
                .frame(width: IPadShellLayout.iconSize, height: IPadShellLayout.iconSize)
                .foregroundStyle(Constants.Pairing.foreground(for: colorScheme))
                .frame(width: IPadShellLayout.railWidth, height: IPadShellLayout.railWidth)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: IPadShellLayout.cornerRadius)
                            .fill(Constants.Pairing.surface(for: colorScheme))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: IPadShellLayout.cornerRadius))
                .accessibilityHidden(true)
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
        .help(label)
    }

    private var appearanceTitle: String {
        switch themePreference {
        case "light": "Light Mode"
        case "dark": "Dark Mode"
        default: "System"
        }
    }

    private var appearanceIcon: ImageResource {
        switch themePreference {
        case "light": .brightnessFull
        case "dark": .night
        default: .brightnessRise
        }
    }
}
