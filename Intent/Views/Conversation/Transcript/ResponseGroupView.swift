import SwiftUI

/// A parsed response group from `<group:Name>...</group>` tags in assistant text.
struct ResponseGroup: Identifiable {
    /// Deterministic id derived by the parser from the group's source
    /// (opening block id + per-block ordinal + name), so re-parsing identical
    /// input yields the same identity and streaming deltas don't reset the
    /// expansion State of an already-rendered group.
    let id: String
    let name: String
    let children: [ContentBlock]

    /// Count of tool_use blocks in this group's children.
    var toolCallCount: Int {
        children.filter { $0.type == .toolUse }.count
    }
}

/// Enum representing either a standalone ContentBlock or a grouped set of blocks.
enum RenderBlock: Identifiable {
    case contentBlock(ContentBlock)
    case group(ResponseGroup)

    var id: String {
        switch self {
        case .contentBlock(let block): return block.id
        case .group(let group): return group.id
        }
    }
}

struct ResponseGroupView: View {
    let group: ResponseGroup
    let isLast: Bool
    let workspaceId: String
    var onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)?
    /// Slim-projection hydration passthrough (PROTOCOL §5.5): in-flight block
    /// ids and the on-demand full-block fetch, forwarded to ContentBlockView.
    var hydratingBlockIds: Set<String> = []
    var onHydrateBlock: ((_ blockId: String) -> Void)?
    @Environment(\.colorScheme) var colorScheme
    @State private var isExpanded: Bool

    init(
        group: ResponseGroup,
        isLast: Bool,
        workspaceId: String,
        onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)? = nil,
        hydratingBlockIds: Set<String> = [],
        onHydrateBlock: ((_ blockId: String) -> Void)? = nil
    ) {
        self.group = group
        self.isLast = isLast
        self.workspaceId = workspaceId
        self.onNavigateToNote = onNavigateToNote
        self.hydratingBlockIds = hydratingBlockIds
        self.onHydrateBlock = onHydrateBlock
        self._isExpanded = State(initialValue: isLast)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header button
            Button {
                withAnimation(.easeInOut(duration: Constants.Conversation.ResponseGroup.expansionAnimationDuration)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.stack")
                        .font(.caption)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(0.6))
                        .accessibilityHidden(true)

                    Text(group.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.foreground(for: colorScheme))

                    if group.toolCallCount > 0 {
                        Text("\(group.toolCallCount)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.background(for: colorScheme))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.mutedForeground(for: colorScheme))
                            .clipShape(Capsule())
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(0.4))
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            // Content with left border
            if isExpanded {
                groupChildrenView
                    .padding(.leading, Constants.Conversation.ResponseGroup.contentIndent)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Theme.mutedForeground(for: colorScheme).opacity(0.15))
                            .frame(width: Constants.Conversation.ResponseGroup.railWidth)
                            .padding(.leading, Constants.Conversation.ResponseGroup.railInset)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                // Collapsed: constrained scrollable preview
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        groupChildrenView
                            .id("group-content-bottom")
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxHeight: Constants.Conversation.ResponseGroup.collapsedMaximumHeight)
                    .mask(
                        VStack(spacing: 0) {
                            LinearGradient(
                                colors: [.clear, .black],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: Constants.Conversation.ResponseGroup.collapsedFadeHeight)
                            Color.black
                        }
                    )
                    .onAppear {
                        proxy.scrollTo("group-content-bottom", anchor: .bottom)
                    }
                }
                .padding(.leading, Constants.Conversation.ResponseGroup.contentIndent)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.mutedForeground(for: colorScheme).opacity(0.15))
                        .frame(width: Constants.Conversation.ResponseGroup.railWidth)
                        .padding(.leading, Constants.Conversation.ResponseGroup.railInset)
                }
                .transition(.opacity)
            }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var groupChildrenView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(group.children) { block in
                ContentBlockView(
                    block: block,
                    allBlocks: group.children,
                    workspaceId: workspaceId,
                    onNavigateToNote: onNavigateToNote,
                    hydratingBlockIds: hydratingBlockIds,
                    onHydrateBlock: onHydrateBlock
                )
            }
        }
    }
}
