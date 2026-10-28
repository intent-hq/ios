import SwiftUI

/// Slash-command skill picker: a horizontally scrolling row of chips above the composer.
/// The highlighted chip uses the accent; Return or a tap inserts it.
struct SkillSuggestionsView: View {
    let completion: ComposerSkillCompletion
    let workspaceId: String
    let connection: any ConnectionManagerRouting
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var retry = 0

    private typealias Palette = Constants.Conversation.Design.Palette

    private enum Layout {
        static let chipCornerRadius: CGFloat = 16
        static let chipHeight: CGFloat = 40
        static let chipHorizontalPadding: CGFloat = 20
        static let chipSpacing: CGFloat = 8
        static let bottomPadding: CGFloat = 12
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: Layout.chipHeight, alignment: .leading)
            .padding(.bottom, Layout.bottomPadding)
            .accessibilityIdentifier("composer.skills")
            .task(id: "\(connection.connectionState == .connected)-\(workspaceId)-\(retry)") {
                completion.catalog.reset()
                guard connection.connectionState == .connected else { return }
                await completion.catalog.load(workspaceId: workspaceId, connection: connection)
            }
            .onDisappear { completion.catalog.reset() }
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
            }
        } else if completion.matches.isEmpty {
            status(completion.catalog.skills.isEmpty ? "No skills available" : "No matching skills")
        } else {
            chips
        }
    }

    private var chips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Layout.chipSpacing) {
                    ForEach(completion.matches) { skill in
                        chip(skill)
                    }
                }
            }
            .scrollClipDisabled()
            .onChange(of: completion.selectedSkill?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func chip(_ skill: SkillInfo) -> some View {
        let selected = completion.selectedSkill?.id == skill.id
        return Button { completion.insert(skill) } label: {
            chipLabel(Text(verbatim: "/\(skill.name)"), selected: selected)
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityIdentifier("composer.skill.\(skill.name)")
        .accessibilityHint(Text(verbatim: skill.description))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .id(skill.id)
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
