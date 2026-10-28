import SwiftUI

/// Slash-command skill picker shown as a one-row chip rail above the composer.
/// The highlighted chip's description sits above the rail; Return or a tap inserts it.
struct SkillSuggestionsView: View {
    let completion: ComposerSkillCompletion
    let workspaceId: String
    let connection: any ConnectionManagerRouting
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var retry = 0

    private typealias Palette = Constants.Conversation.Design.Palette

    private enum Layout {
        static let outerPadding: CGFloat = 8
        static let cornerRadius: CGFloat = 24
        static let chipCornerRadius: CGFloat = 16
        static let chipHeight: CGFloat = 40
        static let chipHorizontalPadding: CGFloat = 20
        static let chipSpacing: CGFloat = 8
        static let railSpacing: CGFloat = 12
        static let summaryTopPadding: CGFloat = 14
        static let bottomPadding: CGFloat = 8
        static let statusPadding: CGFloat = 20
        static let shadowRadius: CGFloat = 10
        static let shadowY: CGFloat = 10
        static let shadowOpacity: Double = 0.08
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.background(for: colorScheme), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Layout.cornerRadius)
                    .strokeBorder(Palette.border(for: colorScheme, contrast: contrast))
            }
            .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
            .shadow(color: .black.opacity(Layout.shadowOpacity), radius: Layout.shadowRadius, y: Layout.shadowY)
            .padding(.horizontal, Layout.outerPadding)
            .padding(.bottom, Layout.outerPadding)
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
                status("Loading skills…", padded: false)
            }
            .padding(Layout.statusPadding)
        } else if completion.catalog.errorMessage != nil {
            HStack {
                status("Skills could not be loaded")
                Spacer(minLength: 0)
                Button { retry += 1 } label: {
                    chipLabel(Text("Retry"), selected: true)
                }
                .buttonStyle(IntentContentButtonStyle())
                .padding(.trailing, Layout.outerPadding)
            }
        } else if completion.matches.isEmpty {
            status(completion.catalog.skills.isEmpty ? "No skills available" : "No matching skills")
        } else {
            rail
        }
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: Layout.railSpacing) {
            if let skill = completion.selectedSkill {
                Text(verbatim: skill.description.isEmpty ? "/\(skill.name)" : skill.description)
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Palette.secondaryForeground(for: colorScheme, contrast: contrast))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, Layout.chipHorizontalPadding)
                    .padding(.top, Layout.summaryTopPadding)
                    .accessibilityHidden(true)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Layout.chipSpacing) {
                        ForEach(completion.matches) { skill in
                            chip(skill)
                        }
                    }
                    .padding(.horizontal, Layout.outerPadding)
                }
                .onChange(of: completion.selectedSkill?.id) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .padding(.bottom, Layout.bottomPadding)
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

    private func status(_ message: LocalizedStringKey, padded: Bool = true) -> some View {
        Text(message)
            .interFont(Constants.Typography.bodyXS)
            .foregroundStyle(Palette.secondaryForeground(for: colorScheme, contrast: contrast))
            .padding(padded ? Layout.statusPadding : 0)
    }
}
