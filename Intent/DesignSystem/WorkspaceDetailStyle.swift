import SwiftUI

enum WorkspaceDetailStyle {
    static let pageInset: CGFloat = 24
    static let headingTopSpacing: CGFloat = 64
    static let headingSpacing: CGFloat = 12
    static let headingBottomSpacing: CGFloat = 24
    static let sectionSpacing: CGFloat = 48
    static let sectionHeadingSpacing: CGFloat = 24
    static let titleTracking: CGFloat = -0.56
    static let rowTitleTracking: CGFloat = -0.36
    static let bodyTracking: CGFloat = -0.16
    static let controlSize: CGFloat = 48
    static let iconSize: CGFloat = 24
    static let tabInset: CGFloat = 4
    static let tabLabelTracking: CGFloat = -0.32
    static let tabCornerRadius: CGFloat = 20
    static let selectedTabCornerRadius: CGFloat = 16
    static let progressHeight: CGFloat = 8
    static let progressBottomSpacing: CGFloat = 56
    static let rowSpacing: CGFloat = 36
    static let avatarSize: CGFloat = 32
    static let avatarSpacing: CGFloat = 24
    static let avatarArtRatio: CGFloat = 0.625
    static let avatarCornerRatio: CGFloat = 0.25
    static let stackAvatarSize: CGFloat = 24
    static let stackSpacing: CGFloat = 16
    static let stackTopSpacing: CGFloat = 16
    static let stackBorderWidth: CGFloat = 1
    static let noteIndentation: CGFloat = 48
    static let accessibilityIndentation: CGFloat = 8
    static let noteTextSpacing: CGFloat = 4
    static let noteTitleSpacing: CGFloat = 8
    static let notePreviewSpacing: CGFloat = 12
    static let taskRowSpacing: CGFloat = 24
    static let checkboxCornerRadius: CGFloat = 8
    static let checkboxStrokeWidth: CGFloat = 2
    static let checkmarkSize: CGFloat = 16
    static let cancelledOpacity: Double = 0.3
    static let accent = Constants.Pairing.accent
    static let onAccent = Constants.Pairing.onAccent

    // Figma grey-400, used for repository text and neutral avatar tiles.
    // swiftlint:disable:next no_magic_numbers
    static let neutral = Color(.sRGB, red: 82 / 255, green: 82 / 255, blue: 80 / 255)

    static func background(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Constants.Pairing.background(for: scheme) : .white
    }

    static func foreground(for scheme: ColorScheme) -> Color {
        Constants.Pairing.foreground(for: scheme)
    }

    static func surface(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Constants.Pairing.surface(for: scheme) : Constants.Pairing.background(for: scheme)
    }

    static func secondary(for scheme: ColorScheme, contrast: ColorSchemeContrast = .standard) -> Color {
        contrast == .increased ? foreground(for: scheme) : Constants.Pairing.mutedForeground(for: scheme)
    }
}

struct ToolbarOverflowLabel: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(.more)
            .resizable()
            .scaledToFit()
            .frame(width: WorkspaceDetailStyle.iconSize, height: WorkspaceDetailStyle.iconSize)
            .foregroundStyle(WorkspaceDetailStyle.foreground(for: colorScheme))
            .frame(minWidth: Constants.Accessibility.minimumTapTarget, minHeight: Constants.Accessibility.minimumTapTarget)
            .accessibilityHidden(true)
    }
}

struct WorkspaceContentTabs: View {
    private static let selectionAnimationDuration = 0.35

    @Binding var selection: WorkspaceTab
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionAnimation

    var body: some View {
        HStack(spacing: 0) {
            tab("Agents", value: .agents)
            tab("Context", value: .context)
            tab("Changes", value: .changes)
        }
        .background {
            if selection == .agents || selection == .context || selection == .changes {
                RoundedRectangle(cornerRadius: WorkspaceDetailStyle.selectedTabCornerRadius)
                    .fill(WorkspaceDetailStyle.foreground(for: colorScheme))
                    .matchedGeometryEffect(id: selection, in: selectionAnimation, isSource: false)
            }
        }
        .padding(WorkspaceDetailStyle.tabInset)
        .background(WorkspaceDetailStyle.surface(for: colorScheme), in: .rect(
            cornerRadius: WorkspaceDetailStyle.tabCornerRadius
        ))
        .animation(reduceMotion ? nil : .snappy(duration: Self.selectionAnimationDuration), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace Content")
    }

    private func tab(_ title: String, value: WorkspaceTab) -> some View {
        Button { selection = value } label: {
            Text(title)
                .interFont(Constants.Typography.bodySEmphasized)
                .tracking(WorkspaceDetailStyle.tabLabelTracking)
                .padding(.vertical, WorkspaceDetailStyle.tabInset)
                .frame(maxWidth: .infinity, minHeight: WorkspaceDetailStyle.controlSize)
                .foregroundStyle(selection == value
                    ? WorkspaceDetailStyle.surface(for: colorScheme)
                    : WorkspaceDetailStyle.foreground(for: colorScheme))
                .contentShape(.rect)
        }
        .buttonStyle(IntentContentButtonStyle())
        .matchedGeometryEffect(id: value, in: selectionAnimation)
        .accessibilityAddTraits(selection == value ? .isSelected : [])
    }
}
