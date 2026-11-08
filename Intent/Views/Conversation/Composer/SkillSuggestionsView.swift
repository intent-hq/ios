import SwiftUI

/// Slash-command skill picker: a horizontally scrolling row of chips above the composer.
/// The highlighted chip uses the accent; Return or a tap inserts it.
struct SkillSuggestionsView: View {
    let completion: ComposerSkillCompletion
    let workspaceId: String
    let agentId: String
    let connection: any ConnectionManagerRouting
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var retry = 0
    @ScaledMetric(relativeTo: .body) private var menuIconSide: CGFloat = 17

    private typealias Palette = Constants.Conversation.Design.Palette

    private enum Layout {
        static let chipCornerRadius: CGFloat = 16
        static let chipHeight: CGFloat = 40
        static let chipHorizontalPadding: CGFloat = 20
        static let chipSpacing: CGFloat = 8
        static let bottomPadding: CGFloat = 12
        static let previewWidth: CGFloat = 320
        static let previewPadding: CGFloat = 20
        static let previewSpacing: CGFloat = 6
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

    private var chips: some View {
        let selectedId = completion.selectedSkill?.id
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Layout.chipSpacing) {
                    ForEach(completion.matches) { skill in
                        chip(skill, selected: skill.id == selectedId)
                    }
                }
            }
            .scrollClipDisabled()
            .onChange(of: selectedId) { _, id in
                guard let id else { return }
                withAnimation(.easeOut) { proxy.scrollTo(id, anchor: .center) }
            }
        }
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

    /// Long-press preview: the chip itself shows only the name.
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
        label
            .interFont(Constants.Typography.bodyXSEmphasized)
            .foregroundStyle(selected ? Palette.onAccent : Palette.foreground(for: colorScheme))
            .lineLimit(1)
            .padding(.horizontal, Layout.chipHorizontalPadding)
            .frame(minHeight: Layout.chipHeight)
            .background(
                selected ? Palette.accent : Palette.surface(for: colorScheme),
                in: RoundedRectangle(cornerRadius: Layout.chipCornerRadius)
            )
            .contentShape(RoundedRectangle(cornerRadius: Layout.chipCornerRadius))
    }

    private func status(_ message: LocalizedStringKey) -> some View {
        Text(message)
            .interFont(Constants.Typography.bodyXS)
            .foregroundStyle(Palette.secondaryForeground(for: colorScheme, contrast: contrast))
            .padding(.horizontal, Layout.chipHorizontalPadding)
    }
}
