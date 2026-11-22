import SwiftUI

struct SkillSuggestionsView: View {
    let completion: ComposerSkillCompletion
    let workspaceId: String
    let agentId: String
    let connection: any ConnectionManagerRouting
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var retry = 0
    @ScaledMetric(relativeTo: .body) private var menuIconSide: CGFloat = 17
    @ScaledMetric(relativeTo: .caption) private var commandIconSide: CGFloat = 14

    private typealias Palette = Constants.Conversation.Design.Palette

    private enum Layout {
        static let chipHeight: CGFloat = 40
        static let chipHorizontalPadding: CGFloat = 20
        static let chipSpacing: CGFloat = 8
        static let bottomPadding: CGFloat = 12
        static let previewWidth: CGFloat = 320
        static let previewPadding: CGFloat = 20
        static let previewSpacing: CGFloat = 6
        static let commandIconSpacing: CGFloat = 6
        static let separatorWidth: CGFloat = 1
        static let separatorHeight: CGFloat = 24
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: Layout.chipHeight, alignment: .leading)
            .padding(.bottom, Layout.bottomPadding)
            .accessibilityIdentifier("composer.skills")
            .task(id: "\(connection.connectionState == .connected)-\(workspaceId)-\(agentId)-\(retry)") {
                await completion.catalog.refresh(workspaceId: workspaceId, agentId: agentId, connection: connection)
            }
    }

    @ViewBuilder
    private var content: some View {
        if connection.connectionState != .connected {
            status("Connect to see available skills")
        } else if !completion.commandMatches.isEmpty {
            chips
        } else if completion.catalog.isLoading {
            HStack(spacing: Layout.chipSpacing) {
                ProgressView()
                status("Loading skills…")
            }
            .padding(.horizontal, Layout.chipHorizontalPadding)
        } else if completion.catalog.errorMessage != nil {
            HStack(spacing: Layout.chipSpacing) {
                status("Skills could not be loaded")
                Button { retry += 1 } label: {
                    chipLabel(Text("Retry"), selected: true)
                }
                .buttonStyle(IntentContentButtonStyle())
                .disabledWhileReadOnly()
            }
        } else if completion.matches.isEmpty {
            status(completion.catalog.skills.isEmpty ? "No skills available" : "No matching skills")
        } else {
            chips
        }
    }

    private var skillsReady: Bool {
        !completion.catalog.isLoading && completion.catalog.errorMessage == nil
    }

    private var chips: some View {
        let selectedId = completion.selectedEntry?.id
        let commands = completion.commandMatches
        let skills = skillsReady ? completion.matches : []
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Layout.chipSpacing) {
                    ForEach(commands) { command in
                        commandChip(command, selected: command.id == selectedId)
                    }
                    if !commands.isEmpty, !skills.isEmpty || !skillsReady {
                        separator
                    }
                    ForEach(skills) { skill in
                        chip(skill, selected: skill.id == selectedId)
                    }
                    if !commands.isEmpty { trailingSkillsState }
                }
            }
            .scrollClipDisabled()
            .onChange(of: selectedId) { _, id in
                guard let id else { return }
                withAnimation(.easeOut) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private var trailingSkillsState: some View {
        if completion.catalog.isLoading {
            ProgressView().accessibilityLabel("Loading skills")
        } else if completion.catalog.errorMessage != nil {
            Button { retry += 1 } label: {
                chipLabel(Text("Retry skills"), selected: false)
            }
            .buttonStyle(IntentContentButtonStyle())
            .disabledWhileReadOnly()
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Theme.border(for: colorScheme))
            .frame(width: Layout.separatorWidth, height: Layout.separatorHeight)
            .accessibilityHidden(true)
    }

    private func commandChip(_ command: SlashBuiltInCommand, selected: Bool) -> some View {
        Button { completion.insert(command) } label: {
            HStack(spacing: Layout.commandIconSpacing) {
                Image(.pin)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: commandIconSide, height: commandIconSide)
                    .accessibilityHidden(true)
                Text(verbatim: "/\(command.name)")
            }
            .modifier(ChipLabelStyle(selected: selected, colorScheme: colorScheme))
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityIdentifier("composer.command.\(command.name)")
        .accessibilityLabel(Text("/\(command.name), built-in command"))
        .accessibilityHint(Text(verbatim: command.description))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .id(command.id)
    }

    private func chip(_ skill: SkillInfo, selected: Bool) -> some View {
        Button { completion.insert(skill) } label: {
            chipLabel(Text(verbatim: "/\(skill.name)"), selected: selected)
        }
        .buttonStyle(IntentContentButtonStyle())
        .contextMenu {
            Button { completion.insert(skill) } label: {
                Label {
                    Text("Use")
                } icon: {
                    Image(.enter)
                        .resizable()
                        .scaledToFit()
                        .frame(width: menuIconSide, height: menuIconSide)
                }
            }
        } preview: {
            skillPreview(skill)
        }
        .accessibilityIdentifier("composer.skill.\(skill.name)")
        .accessibilityHint(Text(verbatim: skill.description))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .id(skill.id)
    }

    private func skillPreview(_ skill: SkillInfo) -> some View {
        VStack(alignment: .leading, spacing: Layout.previewSpacing) {
            Text(verbatim: "/\(skill.name)")
                .interFont(Constants.Typography.bodySEmphasized)
                .foregroundStyle(Palette.foreground(for: colorScheme))
            if !skill.description.isEmpty {
                Text(verbatim: skill.description)
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Palette.secondaryForeground(for: colorScheme, contrast: contrast))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Layout.previewPadding)
        .frame(width: Layout.previewWidth, alignment: .leading)
        .background(Palette.background(for: colorScheme))
        .accessibilityIdentifier("composer.skill.preview")
    }

    private func chipLabel(_ label: Text, selected: Bool) -> some View {
        label.modifier(ChipLabelStyle(selected: selected, colorScheme: colorScheme))
    }

    private func status(_ message: LocalizedStringKey) -> some View {
        Text(message)
            .interFont(Constants.Typography.bodyXS)
            .foregroundStyle(Palette.secondaryForeground(for: colorScheme, contrast: contrast))
            .padding(.horizontal, Layout.chipHorizontalPadding)
    }
}

private struct ChipLabelStyle: ViewModifier {
    private typealias Palette = Constants.Conversation.Design.Palette

    private static let cornerRadius: CGFloat = 16
    private static let height: CGFloat = 40
    private static let horizontalPadding: CGFloat = 20

    let selected: Bool
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        content
            .interFont(Constants.Typography.bodyXSEmphasized)
            .foregroundStyle(selected ? Palette.onAccent : Palette.foreground(for: colorScheme))
            .lineLimit(1)
            .padding(.horizontal, Self.horizontalPadding)
            .frame(minHeight: Self.height)
            .background(
                selected ? Palette.accent : Palette.surface(for: colorScheme),
                in: RoundedRectangle(cornerRadius: Self.cornerRadius)
            )
            .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
    }
}
