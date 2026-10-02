import CoreText
import SwiftUI

extension View {
    @ViewBuilder
    func workspacePhoneNavigation<Actions: View>(
        title: String,
        onBack: @escaping () -> Void,
        @ViewBuilder actions: @escaping () -> Actions
    ) -> some View {
        #if os(iOS)
        modifier(WorkspacePhoneNavigationModifier(title: title, onBack: onBack, actions: actions))
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct WorkspacePhoneNavigationModifier<Actions: View>: ViewModifier {
    let title: String
    let onBack: () -> Void
    @ViewBuilder let actions: () -> Actions
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        content
            .toolbar(horizontalSizeClass == .compact ? .hidden : .automatic, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                if horizontalSizeClass == .compact {
                    WorkspaceNavigationHeader(
                        title: title,
                        subtitle: "Workspace",
                        backLabel: "Back to workspaces",
                        backIdentifier: "workspaceDetail.back",
                        onBack: onBack,
                        actions: actions
                    )
                }
            }
    }
}
#endif

struct WorkspaceConversationHeader<Actions: View>: View {
    let title: String
    let onBack: () -> Void
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        WorkspaceNavigationHeader(
            title: title,
            subtitle: "Agent",
            backLabel: "Back",
            backIdentifier: "conversation.back",
            onBack: onBack,
            actions: actions
        )
    }
}

/// Workspace and agent navigation share the native top safe area and control geometry.
struct WorkspaceNavigationHeader<Actions: View>: View {
    let title: String
    let subtitle: LocalizedStringKey
    let backLabel: LocalizedStringKey
    let backIdentifier: String
    let onBack: () -> Void
    @ViewBuilder let actions: () -> Actions
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private typealias Design = Constants.Conversation.Design

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onBack) {
                Image(.arrowLeft)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Design.iconSize, height: Design.iconSize)
                    .frame(width: Design.Header.controlSize, height: Design.Header.controlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(backLabel)
            .accessibilityIdentifier(backIdentifier)
            VStack(spacing: Design.Header.titleSpacing) {
                WorkspaceHeaderText(Text(title), style: Constants.Typography.bodyXSEmphasized, lineLimit: 1)
                WorkspaceHeaderText(Text(subtitle), style: Constants.Typography.bodyXS)
                    .foregroundStyle(Design.Palette.subtitleForeground(for: colorScheme, contrast: contrast))
            }
            .tracking(Design.Typography.smallTracking)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            actions()
                .buttonStyle(.plain)
                .frame(width: Design.Header.controlSize, height: Design.Header.controlSize)
        }
        .foregroundStyle(Design.Palette.foreground(for: colorScheme))
        .padding(.horizontal, Design.horizontalInset)
        .padding(.vertical, Design.Header.verticalPadding)
        .background(Design.Palette.background(for: colorScheme))
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
