import SwiftUI

struct IPadAssistantSidebar: View {
    let session: BackendSession
    let onCollapse: () -> Void
    let onSelectThread: (String) -> Void
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var store: AssistantStore { session.assistantStore }
    private var selectedID: String? { coordinator.assistantAgentId ?? store.threads.first?.id }

    var body: some View {
        VStack(spacing: 0) {
            IPadSidebarHeader(onCollapse: onCollapse) {
                IPadSidebarTitle(title: "Assistant")
            } actions: {
                IntentIconButton(icon: .addIcon, label: "New conversation", showsBackground: false, action: createThread)
                    .disabled(store.isCreating || !store.hasLoaded)
                    .accessibilityIdentifier("assistant.sidebar.newConversation")
            }
            ScrollView {
                VStack(spacing: 0) {
                    if let error = store.errorMessage {
                        AssistantErrorBanner(error: error) { Task { await store.refresh() } }
                    }
                    if store.threads.isEmpty {
                        emptyState
                    } else {
                        threadRows
                    }
                }
                .padding(.horizontal, IPadSidebarStyle.inset)
                .padding(.bottom, IPadSidebarStyle.inset)
            }
            .refreshable { await store.refresh() }
        }
        .background(IPadSidebarStyle.background(for: colorScheme))
        .task { if !store.hasLoaded { await store.refresh() } }
    }

    private var threadRows: some View {
        let rows = store.threads.map { (id: $0.id, content: threadRow($0)) }
        return LazyVStack(spacing: 0) {
            ForEach(rows, id: \.id) { @Sendable row in row.content }
        }
    }

    private var emptyState: some View {
        AssistantStateContent(
            isLoading: store.isLoading || (!store.hasLoaded && store.errorMessage == nil),
            canCreateConversation: !store.isCreating && store.hasLoaded,
            onCreateConversation: createThread
        )
    }

    private func threadRow(_ thread: AgentSession) -> some View {
        let selected = selectedID == thread.id
        return Button { onSelectThread(thread.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: Constants.WorkspaceRow.metadataSpacing) {
                Text(thread.name)
                    .interFont(Constants.Typography.bodySEmphasized)
                    .foregroundStyle(Constants.Pairing.foreground(for: colorScheme))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let date = ISO8601DateFormatter.lenientDate(from: thread.bestTimestamp) {
                    Text(date.relativeFormatted)
                        .interFont(Constants.Typography.subtextXXS)
                        .foregroundStyle(Constants.WorkspaceList.secondaryText(for: colorScheme, contrast: contrast))
                        .fixedSize()
                }
            }
            .padding(.horizontal, IPadSidebarStyle.rowInset)
            .padding(.vertical, Constants.WorkspaceRow.verticalPadding)
            .frame(minHeight: IPadSidebarStyle.rowHeight)
            .background(
                selected ? IPadSidebarStyle.selection(for: colorScheme) : .clear,
                in: .rect(cornerRadius: IPadSidebarStyle.rowRadius)
            )
            .overlay(alignment: .bottom) {
                if !selected { Divider() }
            }
            .contentShape(.rect)
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("assistant.thread.\(thread.id)")
    }

    private func createThread() {
        Task {
            if let id = await store.createThread() {
                onSelectThread(id)
            }
        }
    }
}
