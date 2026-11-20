import SwiftUI

/// An authored response group or a generated tool activity summary.
struct ResponseGroup: Identifiable, Equatable {
    struct Activity: Equatable {
        let tools: Int
        let thinking: Int

        var label: String {
            let toolsLabel = tools == 1 ? String(localized: "1 tool call") : String(localized: "\(tools) tool calls")
            let thinkingLabel = thinking == 1
                ? String(localized: "1 thinking step")
                : String(localized: "\(thinking) thinking steps")
            if tools == 0 { return thinkingLabel }
            if thinking == 0 { return toolsLabel }
            return String(localized: "\(toolsLabel) · \(thinkingLabel)")
        }
    }

    let id: String
    let name: String
    let children: [ContentBlock]
    var activity: Activity?

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
        switch self {
        case .contentBlock(let block): block.isToolActivity
        case .group(let group): group.activity != nil
        }
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
    private var expandsByDefault: Bool { isLast && group.activity == nil }
    private var isExpanded: Bool {
        get { disclosure.binding(for: .group(group.id), default: expandsByDefault).wrappedValue }
        nonmutating set { disclosure.binding(for: .group(group.id), default: expandsByDefault).wrappedValue = newValue }
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
        .padding(.bottom, group.activity == nil ? Layout.bottomPadding : 0)
        .onAppear { disclosure.initialize(.group(group.id), default: expandsByDefault) }
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
        if workspaceDesign || group.activity != nil {
            HStack(spacing: Design.Transcript.toolLabelSpacing) {
                Image(.fileList)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Design.toolIconSize, height: Design.toolIconSize)
                    .accessibilityHidden(true)
                Text(group.activity?.label ?? group.name)
                    .interFont(Constants.Typography.bodyS)
                    .tracking(Design.Typography.bodyTracking)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if group.activity == nil, group.toolCallCount > 0 {
                    Text("\(group.toolCallCount)")
                        .interFont(Constants.Typography.bodyXS)
                }
                WorkspaceTranscriptDisclosure(isExpanded: isExpanded)
            }
            .foregroundStyle(isExpanded ? Design.Palette.foreground(for: colorScheme)
                : Design.Palette.secondaryForeground(for: colorScheme, contrast: contrast))
            .opacity(collapsedHeaderOpacity)
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

    private var collapsedHeaderOpacity: Double {
        guard group.activity != nil, !isExpanded, contrast == .standard else { return 1 }
        return colorScheme == .dark ? Layout.collapsedSummaryDarkOpacity : Layout.collapsedSummaryLightOpacity
    }

    @ViewBuilder
    private var groupContent: some View {
        if isExpanded {
            groupChildrenView
                .padding(.leading, workspaceDesign ? Design.Transcript.expandedContentIndent : Layout.contentIndent)
                .overlay(alignment: .leading) { if !workspaceDesign { contentRail } }
                .transition(.opacity.combined(with: .move(edge: .top)))
        } else if group.activity == nil {
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
