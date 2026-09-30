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

    var body: some View {
        ZStack {
            Theme.background(for: colorScheme).ignoresSafeArea()
            specialistContent
        }
        .navigationTitle("New Agent")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                }
                .accessibilityLabel("Close")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Next", action: onNext)
                    .disabled(selectedSpecialist == nil)
                    .interFont(Constants.Typography.bodyS.withFace(.semibold))
            }
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
                Image(systemName: "checkmark")
                    .foregroundStyle(Theme.primary(for: colorScheme))
                    .fontWeight(.semibold)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Constants.ModalPicker.rowVerticalPadding)
        .contentShape(Rectangle())
    }
}
