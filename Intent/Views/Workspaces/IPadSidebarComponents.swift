import SwiftUI

/// Section chrome shared by the persistent iPad sidebars.
enum IPadSidebarStyle {
    static let inset: CGFloat = 24
    static let topInset: CGFloat = 32
    static let sectionSpacing: CGFloat = 48
    static let settingsSpacing: CGFloat = 40
    static let rowHeight: CGFloat = 64
    static let rowInset: CGFloat = 20
    static let rowRadius: CGFloat = 16
    static let titleSize: CGFloat = 24
    static let titleTracking: CGFloat = -0.72
    static let titleStyle = Constants.Typography.Style(face: .semibold, size: titleSize, relativeTo: .title2)

    static func background(for scheme: ColorScheme) -> Color {
        SettingsStyle.surface(for: scheme)
    }

    static func selection(for scheme: ColorScheme) -> Color {
        Constants.Connections.surface(for: scheme)
    }
}

struct IPadSidebarTitle: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .interFont(IPadSidebarStyle.titleStyle)
            .tracking(IPadSidebarStyle.titleTracking)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

struct IPadSidebarHeader<Title: View, Actions: View>: View {
    let onCollapse: () -> Void
    @ViewBuilder let title: () -> Title
    @ViewBuilder let actions: () -> Actions
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isIPadPaneVisible) private var isPaneVisible

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Constants.WorkspaceSearch.contentSpacing) {
                    title()
                    controls.frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(spacing: 0) {
                    title().frame(maxWidth: .infinity, alignment: .leading)
                    controls
                }
            }
        }
        .foregroundStyle(Constants.Pairing.foreground(for: colorScheme))
        .padding(.horizontal, IPadSidebarStyle.inset)
        .padding(.top, IPadSidebarStyle.topInset)
        .padding(.bottom, IPadSidebarStyle.sectionSpacing)
    }

    private var controls: some View {
        HStack(spacing: 0) {
            if isPaneVisible {
                actions()
                IntentIconButton(icon: .collapseLeft, label: "Hide sidebar", showsBackground: false, action: onCollapse)
                    .accessibilityIdentifier("ipad.sidebar.collapse")
                    .accessibilityAction(.escape, onCollapse)
            } else {
                Color.clear.frame(width: Constants.WorkspaceSearch.compactHeight, height: Constants.WorkspaceSearch.compactHeight)
            }
        }
    }
}
