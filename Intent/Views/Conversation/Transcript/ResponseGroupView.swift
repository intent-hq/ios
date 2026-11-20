import SwiftUI

struct ResponseGroup: Identifiable, Equatable {
    let id: String
    let name: String
    let children: [ContentBlock]

    var toolCallCount: Int {
        children.filter { $0.type == .toolUse }.count
    }
}

enum RenderBlock: Identifiable {
    case contentBlock(ContentBlock)
    case group(ResponseGroup)

    var id: String {
        switch self {
        case .contentBlock(let block): return block.id
        case .group(let group): return group.id
        }
    }

    var isToolActivity: Bool {
        if case .contentBlock(let block) = self { return block.isToolActivity }
        return false
    }
}

struct ResponseGroupView: View {
    let group: ResponseGroup
    let isLast: Bool
    let workspaceId: String
    var onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)?
    var toolResults: [String: ContentBlock] = [:]
    var hydratingBlockIds: Set<String> = []
    var onLayoutChange: (() -> Void)?
    var onHydrateBlock: ((_ blockId: String) -> Void)?

    var body: some View {
        ResponseGroupBody(
            group: group,
            isLast: isLast,
            workspaceId: workspaceId,
            onNavigateToNote: onNavigateToNote,
            toolResults: toolResults,
            hydratingBlockIds: hydratingBlockIds,
            onLayoutChange: onLayoutChange,
            onHydrateBlock: onHydrateBlock
        )
        .equatable()
    }
}

struct ResponseGroupBody: View, Equatable {
    let group: ResponseGroup
    let isLast: Bool
    let workspaceId: String
    var onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)?
    let toolResults: [String: ContentBlock]
    let hydratingBlockIds: Set<String>
    var onLayoutChange: (() -> Void)?
    var onHydrateBlock: ((_ blockId: String) -> Void)?
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.workspaceTranscriptDesign) private var workspaceDesign
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var groupIconSide: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var disclosureIconSide: CGFloat = 11
    var disclosure = TranscriptDisclosure()
    private var isExpanded: Bool {
        get { disclosure.binding(for: .group(group.id), default: isLast).wrappedValue }
        nonmutating set { disclosure.binding(for: .group(group.id), default: isLast).wrappedValue = newValue }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.group == rhs.group
            && lhs.isLast == rhs.isLast
            && lhs.workspaceId == rhs.workspaceId
            && lhs.toolResults == rhs.toolResults
            && lhs.hydratingBlockIds == rhs.hydratingBlockIds
    }

    private typealias Layout = Constants.Conversation.ResponseGroup
    private typealias Design = Constants.Conversation.Design

    init(
        group: ResponseGroup,
        isLast: Bool,
        workspaceId: String,
        onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)? = nil,
        toolResults: [String: ContentBlock] = [:],
        hydratingBlockIds: Set<String> = [],
        onLayoutChange: (() -> Void)? = nil,
        onHydrateBlock: ((_ blockId: String) -> Void)? = nil
    ) {
        self.group = group
        self.isLast = isLast
        self.workspaceId = workspaceId
        self.onNavigateToNote = onNavigateToNote
        self.toolResults = toolResults
        self.hydratingBlockIds = hydratingBlockIds
        self.onLayoutChange = onLayoutChange
        self.onHydrateBlock = onHydrateBlock
    }

    var body: some View {
        VStack(alignment: .leading, spacing: workspaceDesign ? Design.Transcript.toolRowSpacing : Layout.groupSpacing) {
            headerButton
            groupContent
        }
        .padding(.bottom, Layout.bottomPadding)
        .onAppear { disclosure.initialize(.group(group.id), default: isLast) }
    }

    private var headerButton: some View {
        Button {
            onLayoutChange?()
            withAnimation(reduceMotion ? nil : .easeInOut(duration: Layout.expansionAnimationDuration)) {
                isExpanded.toggle()
            }
        } label: {
            headerLabel
                .copyContextMenuPassthrough()
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    @ViewBuilder
    private var headerLabel: some View {
        if workspaceDesign {
            HStack(spacing: Design.Transcript.toolLabelSpacing) {
                Image(.fileList)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Design.toolIconSize, height: Design.toolIconSize)
                    .accessibilityHidden(true)
                Text(group.name)
                    .interFont(Constants.Typography.bodyS)
                    .tracking(Design.Typography.bodyTracking)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if group.toolCallCount > 0 {
                    Text("\(group.toolCallCount)")
                        .interFont(Constants.Typography.bodyXS)
                }
                WorkspaceTranscriptDisclosure(isExpanded: isExpanded)
            }
            .foregroundStyle(isExpanded ? Design.Palette.foreground(for: colorScheme)
                : Design.Palette.secondaryForeground(for: colorScheme, contrast: contrast))
            .frame(minHeight: Design.minimumTapTarget)
            .contentShape(Rectangle())
        } else {
            HStack(spacing: Layout.headerSpacing) {
                Image(.fileList)
                    .resizable()
                    .scaledToFit()
                    .frame(width: groupIconSide, height: groupIconSide)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(Layout.iconOpacity))
                    .accessibilityHidden(true)
                Text(group.name)
                    .interFont(Constants.Typography.bodyXS.withFace(.semibold))
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                if group.toolCallCount > 0 {
                    Text("\(group.toolCallCount)")
                        .interFont(Constants.Typography.subtextXXS.withFace(.bold))
                        .foregroundStyle(Theme.background(for: colorScheme))
                        .padding(.horizontal, Layout.countHorizontalPadding)
                        .padding(.vertical, Layout.countVerticalPadding)
                        .background(Theme.mutedForeground(for: colorScheme))
                        .clipShape(Capsule())
                }
                Spacer()
                Image(isExpanded ? .chevronDown : .chevronRight)
                    .resizable()
                    .scaledToFit()
                    .frame(width: disclosureIconSide, height: disclosureIconSide)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(Layout.disclosureOpacity))
                    .accessibilityHidden(true)
            }
            .padding(.vertical, Layout.headerVerticalPadding)
        }
    }

    @ViewBuilder
    private var groupContent: some View {
        if isExpanded {
            groupChildrenView
                .padding(.leading, workspaceDesign ? Design.Transcript.expandedContentIndent : Layout.contentIndent)
                .overlay(alignment: .leading) { if !workspaceDesign { contentRail } }
                .transition(.opacity.combined(with: .move(edge: .top)))
        } else {
            collapsedGroupContent
        }
    }

    private var collapsedGroupContent: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                groupChildrenView
                    .id("group-content-bottom")
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: Constants.Conversation.ResponseGroup.collapsedMaximumHeight)
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: Constants.Conversation.ResponseGroup.collapsedFadeHeight)
                    Color.black
                }
            )
            .onAppear {
                proxy.scrollTo("group-content-bottom", anchor: .bottom)
            }
        }
        .padding(.leading, workspaceDesign ? Design.Transcript.expandedContentIndent : Layout.contentIndent)
        .overlay(alignment: .leading) { if !workspaceDesign { contentRail } }
        .transition(.opacity)
    }

    private var contentRail: some View {
        Rectangle()
            .fill(Theme.mutedForeground(for: colorScheme).opacity(Layout.railOpacity))
            .frame(width: Constants.Conversation.ResponseGroup.railWidth)
            .padding(.leading, Constants.Conversation.ResponseGroup.railInset)
    }

    @ViewBuilder
    private var groupChildrenView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(group.children.enumerated()), id: \.element.id) { index, block in
                let toolResult = toolResults[block.id]
                ContentBlockView(
                    block: block,
                    toolResult: toolResult,
                    workspaceId: workspaceId,
                    onNavigateToNote: onNavigateToNote,
                    isHydrating: hydratingBlockIds.contains(block.id)
                        || (toolResult.map { hydratingBlockIds.contains($0.id) } ?? false),
                    onLayoutChange: onLayoutChange,
                    onHydrateBlock: onHydrateBlock
                )
                .padding(.top, childSpacing(at: index))
            }
        }
    }

    private func childSpacing(at index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        if workspaceDesign, group.children[index - 1].isToolActivity, group.children[index].isToolActivity {
            return 0
        }
        return Layout.childSpacing
    }
}
