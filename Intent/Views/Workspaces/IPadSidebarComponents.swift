import SwiftUI

/// Section chrome shared by the persistent iPad sidebars.
enum IPadSidebarStyle {
    static let inset: CGFloat = 24
    static let compactInset: CGFloat = 8
    static let compactSectionSpacing: CGFloat = 16
    static let topInset = IPadShellLayout.headerInset
    static let sectionSpacing: CGFloat = 48
    static let filterListSpacing: CGFloat = 56
    static let scrollFadeHeight: CGFloat = 32
    static let groupLabelSpacing: CGFloat = 16
    static let settingsSpacing: CGFloat = 40
    static let rowHeight: CGFloat = 64
    static let rowVerticalPadding: CGFloat = 24
    static let rowInset: CGFloat = 20
    static let rowRadius: CGFloat = 16
    static let statusDotSize: CGFloat = 10
    static let titleSize: CGFloat = 24
    static let titleTracking: CGFloat = -0.72
    static let titleStyle = Constants.Typography.Style(face: .semibold, size: titleSize, relativeTo: .title2)

    static func background(for scheme: ColorScheme) -> Color {
        IPadShellStyle.background(for: scheme)
    }

    static func selection(for scheme: ColorScheme) -> Color {
        IPadShellStyle.selection(for: scheme)
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
    @Environment(\.workspaceUsesVerticalBar) private var usesVerticalBar
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isIPadPaneVisible) private var isPaneVisible

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stackedHeader
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) {
                        title().fixedSize().frame(maxWidth: .infinity, alignment: .leading)
                        controls
                    }
                    stackedHeader
                }
            }
        }
        .foregroundStyle(Constants.Pairing.foreground(for: colorScheme))
        .padding(.horizontal, usesVerticalBar ? IPadSidebarStyle.compactInset : IPadSidebarStyle.inset)
        .padding(.top, IPadSidebarStyle.topInset)
        .padding(.bottom, usesVerticalBar ? IPadSidebarStyle.compactSectionSpacing : IPadSidebarStyle.sectionSpacing)
    }

    private var stackedHeader: some View {
        VStack(alignment: .leading, spacing: Constants.WorkspaceSearch.contentSpacing) {
            title()
            controls.frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var controls: some View {
        HStack(spacing: 0) {
            if isPaneVisible {
                actions()
                if !usesVerticalBar {
                    IntentIconButton(icon: .collapseLeft, label: "Hide sidebar", showsBackground: false, action: onCollapse)
                        .accessibilityIdentifier("ipad.sidebar.collapse")
                        .accessibilityAction(.escape, onCollapse)
                }
            } else {
                Color.clear.frame(width: Constants.WorkspaceSearch.compactHeight, height: Constants.WorkspaceSearch.compactHeight)
            }
        }
    }
}
