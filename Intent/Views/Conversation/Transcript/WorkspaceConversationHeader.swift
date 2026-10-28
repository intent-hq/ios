import CoreText
import SwiftUI

extension View {
    @ViewBuilder
    func workspacePhoneNavigation<Actions: View>(
        title: String,
        createdAt: String?,
        showsBackButton: Bool = true,
        showsTitle: Bool = true,
        onBack: @escaping () -> Void,
        @ViewBuilder actions: @escaping () -> Actions
    ) -> some View {
        #if os(iOS)
        modifier(WorkspacePhoneNavigationModifier(
            title: title, createdAt: createdAt, showsBackButton: showsBackButton, showsTitle: showsTitle, onBack: onBack, actions: actions
        ))
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct WorkspacePhoneNavigationModifier<Actions: View>: ViewModifier {
    let title: String
    let createdAt: String?
    let showsBackButton: Bool
    let showsTitle: Bool
    let onBack: () -> Void
    @ViewBuilder let actions: () -> Actions
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.workspaceUsesVerticalBar) private var usesVerticalBar
    @Environment(\.conversationPresentation) private var presentation

    private var usesCustomHeader: Bool {
        presentation == .iPad || (horizontalSizeClass == .compact && !usesVerticalBar)
    }

    func body(content: Content) -> some View {
        content
            // Outside the shell the Duo's vertical toolbar needs the bar; inside it the rail replaces it.
            .toolbar(usesCustomHeader && (!usesVerticalBar || presentation == .iPad) ? .hidden : .automatic, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                if usesCustomHeader { navigationHeader }
            }
    }

    /// The iPad shell names the workspace in its sidebar; the header repeats it only while that sidebar is collapsed.
    private var showsHeaderTitle: Bool {
        presentation != .iPad || (showsTitle && !usesVerticalBar)
    }

    private var navigationHeader: some View {
        WorkspaceNavigationHeader(
            title: title,
            subtitle: showsHeaderTitle ? "Workspace" : nil,
            backLabel: "Back to workspaces",
            backIdentifier: "workspaceDetail.back",
            showsTitle: showsHeaderTitle,
            showsWorkspacePlaceholder: showsHeaderTitle,
            workspaceCreatedAt: createdAt,
            usesConversationLayout: presentation == .iPad,
            showsContextualActions: !usesVerticalBar,
            collapsesWhenEmptyOnRail: true,
            onBack: showsBackButton ? onBack : nil,
            actions: actions
        )
    }
}
#endif

struct WorkspaceConversationHeader<Actions: View>: View {
    let title: String
    var showsBackground = true
    var showsContextualActions = true
    /// The sidebar names the open agent while its workspace sits there, so the header drops its title.
    var showsTitle = true
    var assistantStore: AssistantStore?
    let onBack: () -> Void
    @ViewBuilder let actions: () -> Actions
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        if let assistantStore {
            AssistantConversationHeader(
                title: title,
                showsBackground: showsBackground,
                canCreateConversation: !assistantStore.isCreating && assistantStore.hasLoaded,
                onNewConversation: {
                    Task {
                        if let id = await assistantStore.createThread() {
                            coordinator.assistantAgentId = id
                        }
                    }
                },
                actions: actions
            )
        } else {
            WorkspaceNavigationHeader(
                title: title,
                subtitle: showsTitle ? "Agent" : nil,
                backLabel: "Back",
                backIdentifier: "conversation.back",
                showsBackground: showsBackground,
                showsTitle: showsTitle,
                usesConversationLayout: true,
                showsContextualActions: showsContextualActions,
                collapsesWhenEmptyOnRail: true,
                onBack: onBack,
                actions: actions
            )
        }
    }
}

struct AssistantConversationHeader<Actions: View>: View {
    let title: String
    var showsBackground = true
    let canCreateConversation: Bool
    let onNewConversation: () -> Void
    @ViewBuilder let actions: () -> Actions
    @Environment(\.conversationPresentation) private var presentation

    var body: some View {
        WorkspaceNavigationHeader(
            title: title,
            subtitle: presentation == .iPad || title == "Assistant" ? nil : "Assistant",
            backLabel: "New Conversation",
            backIdentifier: "assistant.newConversation",
            leadingIcon: .displayEdit,
            isLeadingActionEnabled: canCreateConversation,
            showsBackground: showsBackground,
            showsTitle: presentation != .iPad || title != "Assistant",
            usesConversationLayout: true,
            onBack: presentation == .iPad ? nil : onNewConversation,
            actions: actions
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.header")
    }
}

/// Workspace, agent and Assistant navigation share the native top safe area and control geometry.
struct WorkspaceNavigationHeader<Actions: View>: View {
    let title: String
    let subtitle: LocalizedStringKey?
    var backLabel: LocalizedStringKey = "Back"
    var backIdentifier = "conversation.back"
    var leadingIcon: ImageResource = .arrowLeft
    var isLeadingActionEnabled = true
    var showsBackground = true
    var showsTitle = true
    var showsWorkspacePlaceholder = false
    var workspaceCreatedAt: String?
    var usesConversationLayout = false
    var showsContextualActions = true
    /// The workspace overview drops its empty band on the Duo; conversations keep their spacing.
    var collapsesWhenEmptyOnRail = false
    var onBack: (() -> Void)?
    @ViewBuilder let actions: () -> Actions
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.conversationPresentation) private var presentation
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private typealias Design = Constants.Conversation.Design

    @Environment(\.usesDuoContextualRail) private var usesDuoContextualRail
    @Environment(\.isIPadPaneVisible) private var isPaneVisible
    @Environment(\.iPadSidebarCollapse) private var sidebarCollapse

    private var showsInlineActions: Bool { showsContextualActions && !usesDuoContextualRail }
    private var showsHeaderCopy: Bool { showsTitle || showsWorkspacePlaceholder || subtitle != nil }

    private var usesIPadDesign: Bool {
        usesConversationLayout && presentation == .iPad
    }

    /// With its controls on the Duo rail and no copy, the header would only be an empty band over the content.
    private var collapsesOnRail: Bool { collapsesWhenEmptyOnRail && usesDuoContextualRail && !showsHeaderCopy }

    var body: some View {
        Group {
            if collapsesOnRail {
                Color.clear.frame(height: 0)
            } else {
                windowAdaptedControls
                    .background(Design.Palette.background(for: colorScheme).opacity(showsBackground ? 1 : 0))
            }
        }
            .preference(
                key: DuoContextualRailPreference.self,
                value: usesDuoContextualRail && isPaneVisible ? AnyView(railControls) : nil
            )
    }

    @ViewBuilder
    private var windowAdaptedControls: some View {
        #if os(iOS)
        if usesIPadDesign {
            // The shell gutter and header inset keep these controls below system chrome.
            controls
        } else if #available(iOS 26.0, *) {
            // Reserve only the system's actual corner region (including iPad window controls).
            controls.containerCornerOffset(.horizontal, sizeToFit: true)
        } else {
            controls
        }
        #else
        controls
        #endif
    }

    private var controls: some View {
        HStack(spacing: 0) {
            if let onBack, showsInlineActions {
                Button(action: onBack) {
                    Image(leadingIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: Design.iconSize, height: Design.iconSize)
                        .foregroundStyle(isLeadingActionEnabled
                            ? Design.Palette.foreground(for: colorScheme)
                            : CreateWorkspaceFormStyle.disabledForeground(for: colorScheme))
                        .frame(width: Design.Header.controlSize, height: Design.Header.controlSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(IntentContentButtonStyle())
                .disabled(!isLeadingActionEnabled)
                .accessibilityLabel(backLabel)
                .accessibilityIdentifier(backIdentifier)
            } else if usesIPadDesign, showsInlineActions {
                // Balance the trailing menu so Assistant titles share the agent alignment.
                Color.clear
                    .frame(width: Design.Header.controlSize, height: Design.Header.controlSize)
                    .accessibilityHidden(true)
            }
            if sidebarCollapse != nil, showsInlineActions {
                // Balance the sidebar control so the title stays centered.
                Color.clear
                    .frame(width: Design.Header.controlSize, height: Design.Header.controlSize)
                    .accessibilityHidden(true)
            }
            headerCopy
            if showsInlineActions {
                IPadSidebarCollapseActions(collapse: sidebarCollapse) {
                    actions()
                        .buttonStyle(IntentContentButtonStyle())
                        .frame(minWidth: Design.Header.controlSize, minHeight: Design.Header.controlSize)
                }
            }
        }
        .foregroundStyle(Design.Palette.foreground(for: colorScheme))
        .padding(.horizontal, Design.horizontalInset)
        .padding(.top, usesIPadDesign ? Design.IPad.headerTopInset : Design.Header.verticalPadding)
        .padding(.bottom, usesIPadDesign ? Design.IPad.headerBottomInset : Design.Header.verticalPadding)
    }

    @ViewBuilder private var headerCopy: some View {
        if showsHeaderCopy {
            titleCopy
        } else {
            Spacer(minLength: 0)
        }
    }

    private var railControls: some View {
        VStack(spacing: IPadShellLayout.contextualRailSpacing) {
            if let onBack {
                IntentIconButton(icon: leadingIcon, label: backLabel, showsBackground: false, action: onBack)
                    .frame(width: IPadShellLayout.railWidth, height: IPadShellLayout.railWidth)
                    .disabled(!isLeadingActionEnabled)
                    .accessibilityIdentifier(backIdentifier)
            }
            actions()
                .frame(width: IPadShellLayout.railWidth)
        }
        .foregroundStyle(Design.Palette.foreground(for: colorScheme))
        .accessibilityIdentifier("duo.contextual.rail")
    }

    private var titleCopy: some View {
        VStack(spacing: Design.Header.titleSpacing) {
            if showsWorkspacePlaceholder {
                WorkspaceTitle(title: title, createdAt: workspaceCreatedAt) { title in
                    WorkspaceHeaderText(Text(title), style: Constants.Typography.bodyXSEmphasized, lineLimit: 1)
                }
            } else if showsTitle {
                WorkspaceHeaderText(
                    Text(title),
                    style: Constants.Typography.bodyXSEmphasized,
                    lineLimit: usesIPadDesign && dynamicTypeSize.isAccessibilitySize ? nil : 1
                )
            }
            subtitleText
        }
        .tracking(Design.Typography.smallTracking)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(showsTitle ? "conversation.header.title" : "")
    }

    @ViewBuilder private var subtitleText: some View {
        if let subtitle {
            WorkspaceHeaderText(Text(subtitle), style: Constants.Typography.bodyXS)
                .foregroundStyle(Design.Palette.subtitleForeground(for: colorScheme, contrast: contrast))
        }
    }
}

/// Measure cap top to final baseline without clipping native glyphs or descenders.
private struct WorkspaceHeaderText: View {
    let text: Text
    let style: Constants.Typography.Style
    let lineLimit: Int?
    @Environment(\.legibilityWeight) private var legibilityWeight
    @ScaledMetric private var fontSize: CGFloat

    init(_ text: Text, style: Constants.Typography.Style, lineLimit: Int? = nil) {
        self.text = text
        self.style = style
        self.lineLimit = lineLimit
        _fontSize = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTo)
    }

    var body: some View {
        let face = legibilityWeight == .bold ? style.face.legibleFace : style.face
        let font = CTFontCreateWithName(face.rawValue as CFString, fontSize, nil)
        WorkspaceTextTrimLayout(capHeight: CTFontGetCapHeight(font)) {
            text
                .interFont(style)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Opt-in cap-to-baseline measurement for workspace text with native baselines.
struct WorkspaceTextTrimLayout: Layout {
    let capHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        let dimensions = text.dimensions(in: ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(
            width: dimensions.width,
            height: dimensions[.lastTextBaseline] - dimensions[.firstTextBaseline] + capHeight
        )
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard let text = subviews.first else { return }
        let proposal = ProposedViewSize(width: bounds.width, height: nil)
        let baseline = text.dimensions(in: proposal)[.firstTextBaseline]
        text.place(at: CGPoint(x: bounds.minX, y: bounds.minY + capHeight - baseline), proposal: proposal)
    }
}

struct WorkspaceGoToEndLabel: View {
    @Environment(\.colorScheme) private var colorScheme

    private typealias Design = Constants.Conversation.Design

    var body: some View {
        HStack(spacing: Design.Status.goToEndIconSpacing) {
            Image(.arrowDown)
                .resizable()
                .scaledToFit()
                .frame(width: Design.smallIconSize, height: Design.smallIconSize)
                .opacity(Design.Status.goToEndIconOpacity)
                .accessibilityHidden(true)
            Text("Go To End")
                .interFont(Design.Typography.status)
        }
        .foregroundStyle(Design.Palette.foreground(for: colorScheme))
        .padding(.leading, Design.Status.goToEndLeadingPadding)
        .padding(.trailing, Design.Status.goToEndTrailingPadding)
        .frame(minHeight: Design.Status.minimumHeight)
        .background(Design.Palette.surface(for: colorScheme), in: Capsule())
        .frame(minHeight: Design.minimumTapTarget)
        .contentShape(Rectangle())
    }
}

/// The outer display keeps native rail actions, while its title owns the top inset.
struct WorkspaceVerticalConversationHeader: View {
    let title: String
    let workspaceId: String
    @Environment(BackendSession.self) private var session
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .interFont(Constants.Typography.bodyM.withFace(.semibold))
                .foregroundStyle(Theme.foreground(for: colorScheme))
                .lineLimit(1)
            if let subtitle = WorkspaceSubtitleResolver.subtitle(forWorkspaceId: workspaceId, in: session.workspaceStore.workspaces) {
                Text(subtitle)
                    .interFont(Constants.Typography.subtextXXS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WorkspaceDetailStyle.pageInset)
        .padding(.vertical, IPadShellLayout.outerInset)
        .background(Constants.Conversation.Design.Palette.background(for: colorScheme).ignoresSafeArea(edges: .top))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("conversation.outer.header")
    }
}

struct DuoContextualRailPreference: PreferenceKey {
    static var defaultValue: AnyView? { nil }

    static func reduce(value: inout AnyView?, nextValue: () -> AnyView?) {
        if let next = nextValue() { value = next }
    }
}

extension EnvironmentValues {
    @Entry var usesDuoContextualRail = false
}
