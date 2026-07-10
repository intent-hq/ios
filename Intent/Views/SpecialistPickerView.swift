import SwiftUI

struct SpecialistPickerView: View {
    let workspaceId: String
    @ObservedObject var agentStore: AgentStore
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) var colorScheme

    @State private var specialists: [SpecialistInfo] = []
    @State private var isLoadingSpecialists = true
    @State private var isCreating = false
    @State private var creatingSpecialistId: String?
    @State private var selectedSpecialist: SpecialistInfo?
    @State private var agentName: String = ""
    @State private var userEditedName: Bool = false
    @State private var isSettingNameFromSpecialist: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background(for: colorScheme).ignoresSafeArea()

                if isLoadingSpecialists {
                    ProgressView("Loading specialists...")
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                } else if specialists.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.rectangle.badge.plus")
                            .font(.largeTitle)
                            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        Text("No specialists available")
                            .font(.headline)
                            .foregroundStyle(Theme.foreground(for: colorScheme))
                    }
                } else {
                    List {
                        Section("Name") {
                            TextField("Agent name", text: $agentName)
                                .foregroundStyle(Theme.foreground(for: colorScheme))
                        }
                        .listRowBackground(Theme.card(for: colorScheme))

                        ForEach(specialists) { specialist in
                            Button {
                                selectedSpecialist = specialist
                                if !userEditedName {
                                    isSettingNameFromSpecialist = true
                                    agentName = specialist.name
                                }
                            } label: {
                                specialistRow(specialist)
                            }
                            .disabled(isCreating)
                            .listRowBackground(Theme.card(for: colorScheme))
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }

                if isCreating {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Creating agent...")
                            .font(.subheadline)
                            .foregroundStyle(Theme.foreground(for: colorScheme))
                    }
                    .padding(24)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .navigationTitle("New Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(Theme.foreground(for: colorScheme))
                    }
                    .disabled(isCreating)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") {
                        if let specialist = selectedSpecialist {
                            createAgentWithSpecialist(specialist)
                        }
                    }
                    .disabled(selectedSpecialist == nil || isCreating)
                    .fontWeight(.semibold)
                }
            }
        }
        .onChange(of: agentName) {
            if isSettingNameFromSpecialist {
                isSettingNameFromSpecialist = false
            } else {
                userEditedName = true
            }
        }
        .task {
            specialists = await agentStore.fetchSpecialists()
            isLoadingSpecialists = false
            // Default to Coordinator specialist
            if let coordinatorSpecialist = specialists.first(where: { $0.id == "spec-writer" }) {
                selectedSpecialist = coordinatorSpecialist
                isSettingNameFromSpecialist = true
                agentName = coordinatorSpecialist.name
            }
        }
    }

    @ViewBuilder
    private func specialistRow(_ specialist: SpecialistInfo) -> some View {
        HStack(spacing: 12) {
            AuggieAvatarView(seed: specialist.id, size: 28, specialist: specialist.id)

            VStack(alignment: .leading, spacing: 4) {
                Text(specialist.name)
                    .font(.headline)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                Text(specialist.description)
                    .font(.subheadline)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .lineLimit(2)
            }

            Spacer()

            if creatingSpecialistId == specialist.id {
                ProgressView()
                    .controlSize(.small)
            } else if selectedSpecialist?.id == specialist.id {
                Image(systemName: "checkmark")
                    .foregroundStyle(Theme.primary(for: colorScheme))
                    .fontWeight(.semibold)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func createAgentWithSpecialist(_ specialist: SpecialistInfo) {
        guard !isCreating else { return }
        isCreating = true
        creatingSpecialistId = specialist.id

        Task {
            do {
                let agent = try await agentStore.createAgent(
                    workspaceId: workspaceId,
                    specialistId: specialist.id,
                    name: agentName.isEmpty ? nil : agentName
                )
                HapticManager.notification(.success)
                dismiss()
                if let agent = agent {
                    coordinator.onSelectAgent(agent.id, workspaceId: workspaceId, agentName: agent.name)
                }
            } catch {
                print("[SpecialistPicker] Failed to create agent: \(error)")
            }
            isCreating = false
            creatingSpecialistId = nil
        }
    }
}

