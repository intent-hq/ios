import CoreText
import SwiftUI

/// Chrome for the workspace overview while it sits in the iPad shell's sidebar
/// beside one of its agents or notes. The main view's Back leaves it.
struct WorkspaceDetailSidebar {
    let onCollapse: () -> Void
}

struct WorkspaceSidebarEditableTitle: View {
    let workspaceId: String
    let workspace: Workspace?
    let titleEditor: WorkspaceTitleEditor
    let titleFocus: FocusState<Bool>.Binding
    let onSaveTitle: () -> Void

    var body: some View {
        WorkspaceDetailHeading(
            workspaceId: workspaceId,
            title: workspace?.title ?? "",
            createdAt: workspace?.createdAt,
            repositoryOwner: nil,
            repositoryName: nil,
            titleEditor: titleEditor,
            titleFocus: titleFocus,
            usesSidebarTitle: true,
            showsOnlyTitle: true,
            onSaveTitle: onSaveTitle
        )
    }
}

struct WorkspaceSidebarHeader<Title: View, Actions: View>: View {
    @ViewBuilder let title: () -> Title
    @ViewBuilder let actions: () -> Actions
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isIPadPaneVisible) private var isPaneVisible
    @Environment(\.legibilityWeight) private var legibilityWeight
    @ScaledMetric(relativeTo: .title2) private var titleSize = IPadSidebarStyle.titleSize

    private var titleTopInset: CGFloat {
        let face = legibilityWeight == .bold ? IPadSidebarStyle.titleStyle.face.legibleFace : IPadSidebarStyle.titleStyle.face
        let font = CTFontCreateWithName(face.rawValue as CFString, titleSize, nil)
        return max(0, (WorkspaceDetailStyle.controlSize - CTFontGetCapHeight(font)) / 2)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            title()
                .padding(.top, titleTopInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions()
        }
        .frame(minHeight: WorkspaceDetailStyle.controlSize, alignment: .top)
        .opacity(isPaneVisible ? 1 : 0)
        .foregroundStyle(Constants.Pairing.foreground(for: colorScheme))
        .padding(.horizontal, IPadSidebarStyle.inset)
        .padding(.top, IPadSidebarStyle.topInset)
        .padding(.bottom, IPadSidebarStyle.sectionSpacing)
    }
}

/// The Duo's sidebar workspace names itself in the list header's slot: same component,
/// type and insets as "Workspaces", fixed above the scrolling page.
struct WorkspaceSidebarTitleHeader: View {
    let title: String

    /// The Duo header shows no collapse control, so its action is never invoked.
    private static func ignoreCollapse() {}

    var body: some View {
        IPadSidebarHeader(onCollapse: Self.ignoreCollapse) {
            Text(title)
                .interFont(IPadSidebarStyle.titleStyle)
                .tracking(IPadSidebarStyle.titleTracking)
                .fixedSize(horizontal: false, vertical: true)
                // The list's row is as tall as its controls; this one has none.
                .frame(minHeight: Constants.WorkspaceSearch.compactHeight)
                .accessibilityAddTraits(.isHeader)
        } actions: {
            EmptyView()
        }
    }
}

extension View {
    /// Marks the open agent or note in a sidebar workspace with the sidebar's selection surface.
    func workspaceSidebarSelection(_ isSelected: Bool) -> some View {
        modifier(WorkspaceSidebarSelection(isSelected: isSelected))
    }
}

private struct WorkspaceSidebarSelection: ViewModifier {
    private static let outset: CGFloat = 12

    let isSelected: Bool
    @Environment(\.workspaceUsesVerticalBar) private var usesVerticalBar
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.conversationPresentation) private var presentation

    func body(content: Content) -> some View {
        content
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: IPadSidebarStyle.rowRadius, style: .continuous)
                        .fill(presentation == .iPad
                            ? IPadSidebarStyle.selection(for: colorScheme)
                            : Theme.sidebarSelection(for: colorScheme))
                        .padding(.vertical, -Self.outset)
                        // The Duo page sits on the list's 8 pt inset, so the fill stops at the column edge.
                        .padding(.horizontal, -(usesVerticalBar ? IPadSidebarStyle.compactInset : Self.outset))
                }
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
