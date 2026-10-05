import SwiftUI

struct WorkspaceTransferSheet: View {
    let workspaceTitle: String
    private let session: BackendSession
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: WorkspaceTransferStore
    @State private var selectedDestinationID: UUID?
    @State private var archiveSource = false
    @State private var isLoadingPreview = true

    private enum Layout {
        static let initialHeight: CGFloat = 640
        static let sectionSpacing: CGFloat = 24
        static let textSpacing: CGFloat = 12
    }

    init(workspaceId: String, workspaceTitle: String, session: BackendSession) {
        self.workspaceTitle = workspaceTitle
        self.session = session
        _store = State(initialValue: WorkspaceTransferStore(workspaceId: workspaceId, source: session.connection))
    }

    private var destinations: [StoredConnection] {
        WorkspaceTransferDestinationPolicy.destinations(
            from: coordinator.savedConnections, sourceID: session.backendID?.connectionID
        )
    }

    private var selectedDestination: StoredConnection? {
        destinations.first { $0.id == selectedDestinationID }
    }

    private var secondary: Color {
        CreateWorkspaceFormStyle.secondary(for: colorScheme, contrast: contrast)
    }

    var body: some View {
        ConnectionSheet(
            initialHeight: Layout.initialHeight,
            backgroundColor: CreateWorkspaceFormStyle.background(for: colorScheme),
            closeForeground: CreateWorkspaceFormStyle.foreground(for: colorScheme),
            isDismissDisabled: store.isBusy
        ) {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                heading
                if store.isComplete {
                    completion
                } else if store.isBusy {
                    transferProgress
                } else {
                    transferForm
                    if !store.statusMessage.isEmpty {
                        Text(store.statusMessage)
                            .interFont(Constants.Typography.bodyXS)
                            .foregroundStyle(secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let error = store.errorMessage {
                    Text(error)
                        .interFont(Constants.Typography.bodyS)
                        .foregroundStyle(Theme.destructive(for: colorScheme))
                        .accessibilityIdentifier("workspace-transfer.error")
                }
                actions
            }
            .foregroundStyle(CreateWorkspaceFormStyle.foreground(for: colorScheme))
            .frame(maxWidth: SettingsStyle.maximumContentWidth)
        }
        .task {
            coordinator.refreshSavedConnectionsPresentation()
            await loadPreview()
        }
        .onDisappear { store.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, store.canCancel { store.cancel() }
        }
        .accessibilityAction(.escape) {
            if !store.isBusy { dismiss() }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: Layout.textSpacing) {
            Text(store.isComplete ? "Workspace transferred" : "Transfer workspace")
                .interFont(Constants.Typography.heading2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("workspace-transfer.title")
            Text(workspaceTitle)
                .interFont(Constants.Typography.bodyS)
                .foregroundStyle(secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var transferForm: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            destinationField
            Toggle(isOn: $archiveSource) {
                Text("Archive on source machine")
                    .interFont(Constants.Typography.bodyS)
            }
            .tint(CreateWorkspaceFormStyle.primary)
            .padding(CreateWorkspaceFormStyle.controlPadding)
            .background(CreateWorkspaceFormStyle.card(for: colorScheme), in: .rect(
                cornerRadius: CreateWorkspaceFormStyle.cornerRadius
            ))
            .accessibilityIdentifier("workspace-transfer.archive-source")
            if let plan = store.plan {
                VStack(alignment: .leading, spacing: Layout.textSpacing) {
                    Text("Estimated size: \(ByteCountFormatter.string(fromByteCount: plan.estimatedBytes, countStyle: .file))")
                    ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning)
                    }
                }
                .interFont(Constants.Typography.bodyXS)
                .foregroundStyle(secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var destinationField: some View {
        VStack(alignment: .leading, spacing: Layout.textSpacing) {
            Text("Destination")
                .interFont(Constants.Typography.bodyXS)
                .foregroundStyle(secondary)
            Menu {
                Picker("Destination", selection: $selectedDestinationID) {
                    Text("Choose a machine").tag(nil as UUID?)
                    ForEach(destinations) { destination in
                        Text(destination.displayName).tag(Optional(destination.id))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                CreateWorkspaceChoiceLabel(title: selectedDestination?.displayName ?? "Choose a machine")
            }
            .buttonStyle(IntentContentButtonStyle())
            .disabled(destinations.isEmpty)
            .accessibilityLabel("Destination")
            .accessibilityValue(selectedDestination?.displayName ?? "Choose a machine")
            .accessibilityIdentifier("workspace-transfer.destination")
            if destinations.isEmpty {
                Text("Pair another machine from Settings to transfer this workspace. You must be an owner on both machines.")
                    .interFont(Constants.Typography.bodyS)
                    .foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var transferProgress: some View {
        VStack(alignment: .leading, spacing: Layout.textSpacing) {
            if let progress = store.progress {
                ProgressView(value: progress)
                    .tint(CreateWorkspaceFormStyle.primary)
            } else {
                ProgressView()
            }
            Text(store.statusMessage)
                .interFont(Constants.Typography.bodyS)
                .accessibilityIdentifier("workspace-transfer.progress")
        }
        .accessibilityElement(children: .combine)
    }

    private var completion: some View {
        Text(store.statusMessage)
            .interFont(Constants.Typography.bodyS)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("workspace-transfer.complete")
    }

    @ViewBuilder private var actions: some View {
        if store.isComplete {
            Button("Done") { dismiss() }
                .buttonStyle(IntentButtonStyle())
        } else if store.isBusy {
            Button(isLoadingPreview ? "Cancel" : "Cancel transfer") { store.cancel() }
                .buttonStyle(IntentButtonStyle(variant: .secondary))
                .disabled(!store.canCancel)
        } else {
            VStack(spacing: Layout.textSpacing) {
                if store.plan == nil {
                    Button("Retry") { Task { await loadPreview() } }
                        .buttonStyle(IntentButtonStyle(variant: .secondary))
                }
                Button {
                    guard let destination = selectedDestination else { return }
                    Task { await store.transfer(to: destination, archiveSource: archiveSource) }
                } label: {
                    Text("Transfer workspace").frame(maxWidth: .infinity)
                }
                .buttonStyle(IntentButtonStyle())
                .disabled(selectedDestination == nil || store.plan == nil
                    || session.connection.connectionState != .connected
                    || session.connection.currentPrincipal?.isOwner != true)
                .accessibilityIdentifier("workspace-transfer.submit")
            }
        }
    }

    private func loadPreview() async {
        isLoadingPreview = true
        await store.loadPlan()
        isLoadingPreview = false
    }
}

enum WorkspaceTransferDestinationPolicy {
    static func destinations(from connections: [StoredConnection], sourceID: UUID?) -> [StoredConnection] {
        let sourcePin = connections.first { $0.id == sourceID }?.server.certFingerprint?.lowercased()
        return connections.filter { connection in
            guard connection.id != sourceID, connection.principal?.isOwner != false else { return false }
            if let sourcePin, connection.server.certFingerprint?.lowercased() == sourcePin { return false }
            return true
        }
    }
}
