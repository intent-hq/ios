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
                    .fontWeight(.semibold)
            }
        }
    }

    @ViewBuilder
    private var specialistContent: some View {
        if isLoadingSpecialists {
            ProgressView("Loading specialists...")
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        } else if specialists.isEmpty {
            VStack(spacing: Constants.ModalPicker.emptyStateSpacing) {
                Image(systemName: "person.crop.rectangle.badge.plus")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .accessibilityHidden(true)
                Text("No specialists available")
                    .font(.headline)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
            }
        } else {
            specialistList
        }
    }

    private var specialistList: some View {
        List {
            Section("Name") {
                TextField("Agent name", text: $agentName)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
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
                    .font(.headline)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                Text(specialist.description)
                    .font(.subheadline)
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
