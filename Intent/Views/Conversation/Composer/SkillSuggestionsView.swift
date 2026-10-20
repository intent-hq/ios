import SwiftUI

struct SkillSuggestionsView: View {
    let completion: ComposerSkillCompletion
    let workspaceId: String
    let connection: any ConnectionManagerRouting
    @Environment(\.colorScheme) private var colorScheme
    @State private var retry = 0
    @ScaledMetric(relativeTo: .body) private var maximumHeight: CGFloat = 216

    private enum Layout {
        static let spacing: CGFloat = 4
        static let padding: CGFloat = 12
        static let minimumRowHeight: CGFloat = 44
        static let cornerRadius: CGFloat = 12
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacing) {
            if connection.connectionState != .connected {
                status("Connect to see available skills")
            } else if completion.catalog.isLoading {
                ProgressView("Loading skills…").padding(Layout.padding)
            } else if completion.catalog.errorMessage != nil {
                HStack {
                    status("Skills could not be loaded")
                    Spacer(minLength: 0)
                    Button("Retry") { retry += 1 }
                        .buttonStyle(IntentContentButtonStyle())
                        .padding(Layout.padding)
                }
            } else if completion.matches.isEmpty {
                status(completion.catalog.skills.isEmpty ? "No skills available" : "No matching skills")
            } else {
                suggestions
            }
        }
        .interFont(Constants.Typography.bodyS)
        .background(Theme.card(for: colorScheme), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
        .padding(.horizontal, Layout.padding)
        .padding(.top, Layout.padding)
        .accessibilityIdentifier("composer.skills")
        .task(id: "\(connection.connectionState == .connected)-\(workspaceId)-\(retry)") {
            completion.catalog.reset()
            guard connection.connectionState == .connected else { return }
            await completion.catalog.load(workspaceId: workspaceId, connection: connection)
        }
        .onDisappear { completion.catalog.reset() }
    }

    private var suggestions: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(completion.matches) { skill in
                        Button { completion.insert(skill) } label: {
                            VStack(alignment: .leading, spacing: Layout.spacing) {
                                Text(verbatim: "/\(skill.name)")
                                    .foregroundStyle(Theme.foreground(for: colorScheme))
                                if !skill.description.isEmpty {
                                    Text(verbatim: skill.description)
                                        .interFont(Constants.Typography.subtextXXS)
                                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                                        .lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: Layout.minimumRowHeight, alignment: .leading)
                            .padding(Layout.padding)
                            .background(completion.selectedSkill?.id == skill.id ? Theme.muted(for: colorScheme) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(IntentContentButtonStyle())
                        .accessibilityIdentifier("composer.skill.\(skill.name)")
                        .id(skill.id)
                    }
                }
            }
            .frame(maxHeight: maximumHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: completion.selectedSkill?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
    }

    private func status(_ message: LocalizedStringKey) -> some View {
        Text(message)
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .padding(Layout.padding)
    }
}
