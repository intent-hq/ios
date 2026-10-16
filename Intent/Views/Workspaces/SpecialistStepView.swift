import SwiftUI

struct SpecialistStepView: View {
    let specialists: [SpecialistInfo]
    let isLoadingSpecialists: Bool
    let selectedSpecialist: SpecialistInfo?
    @Binding var agentName: String
    let colorScheme: ColorScheme
    let onSelect: (SpecialistInfo) -> Void
    let onDismiss: () -> Void
    let onNext: () -> Void
    @Environment(\.workspaceUsesVerticalBar) private var usesVerticalBar
    @ScaledMetric(relativeTo: .body) private var selectionIconSize: CGFloat = 17

    var body: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()
            specialistContent
        }
        .navigationTitle("New Agent")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                IntentIconButton(icon: .close, label: "Close", action: onDismiss)
            }
            .intentToolbarSurface()
            ToolbarItem(placement: .topBarTrailing) {
                Button("Next", action: onNext)
                    .buttonStyle(IntentButtonStyle())
                    // The Duo toolbar otherwise compresses the padded label to an ellipsis.
                    .fixedSize(horizontal: usesVerticalBar, vertical: false)
                    .disabled(selectedSpecialist == nil)
            }
            .intentToolbarSurface()
        }
    }

    @ViewBuilder
    private var specialistContent: some View {
        if isLoadingSpecialists {
            ProgressView {
                Text("Loading specialists...").interFont(Constants.Typography.bodyS)
            }
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        } else if specialists.isEmpty {
            VStack(spacing: Constants.ModalPicker.emptyStateSpacing) {
                Image(systemName: "person.crop.rectangle.badge.plus")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .accessibilityHidden(true)
                Text("No specialists available")
                    .interFont(Constants.Typography.bodyM.withFace(.semibold))
                    .foregroundStyle(Theme.foreground(for: colorScheme))
            }
        } else {
            specialistList
        }
    }

    private var specialistList: some View {
        List {
            Section {
                TextField("Agent name", text: $agentName)
                    .interFont(Constants.Typography.bodyS)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
            } header: {
                Text("Name").interFont(Constants.Typography.eyebrow)
            }
            .listRowBackground(Theme.card(for: colorScheme))
            ForEach(specialists) { specialist in
                Button { onSelect(specialist) } label: { specialistRow(specialist) }
                    .buttonStyle(IntentContentButtonStyle())
                    .listRowBackground(Theme.card(for: colorScheme))
                    .accessibilityAddTraits(
                        selectedSpecialist?.id == specialist.id ? .isSelected : []
                    )
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func specialistRow(_ specialist: SpecialistInfo) -> some View {
        HStack(spacing: Constants.ModalPicker.rowSpacing) {
            AgentAvatarView(
                agentId: specialist.id,
                size: Constants.ModalPicker.rowAvatarSize,
                specialist: specialist.id,
                icon: specialist.icon
            )

            VStack(alignment: .leading, spacing: Constants.ModalPicker.rowTextSpacing) {
                Text(specialist.name)
                    .interFont(Constants.Typography.bodyM.withFace(.semibold))
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                Text(specialist.description)
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .lineLimit(Constants.ModalPicker.rowDescriptionLineLimit)
            }

            Spacer()

            if selectedSpecialist?.id == specialist.id {
                Image(.check)
                    .resizable()
                    .scaledToFit()
                    .frame(width: selectionIconSize, height: selectionIconSize)
                    .foregroundStyle(Theme.primary(for: colorScheme))
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Constants.ModalPicker.rowVerticalPadding)
        .contentShape(Rectangle())
    }
}
