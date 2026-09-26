import SwiftUI

struct ToolCallView: View {
    let block: ContentBlock
    let toolResult: ContentBlock?
    /// True while a slim-truncated body (input or output) is being hydrated
    /// via agent.getMessageBlock (PROTOCOL §5.5).
    var isHydrating: Bool = false
    /// Invalidates the transcript's settled row height before disclosure.
    var onLayoutChange: (() -> Void)?
    /// Fetch the full bodies of this row's slim-truncated blocks; absent →
    /// no hydration (the bounded preview stays).
    var onHydrate: (() -> Void)?
    @Environment(\.colorScheme) var colorScheme
    @ScaledMetric(relativeTo: .caption2) private var iconSize = Constants.Conversation.ToolCall.iconSize
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.workspaceTranscriptDesign) private var workspaceDesign
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var isInputExpanded = false

    private typealias Layout = Constants.Conversation.ToolCall
    private typealias Design = Constants.Conversation.Design

    private var inlineForeground: Color {
        if hasError { return Theme.destructive(for: colorScheme) }
        return isExpanded ? Design.Palette.foreground(for: colorScheme)
            : Design.Palette.secondaryForeground(for: colorScheme, contrast: contrast)
    }

    private var toolName: String {
        block.resolvedName ?? "tool"
    }

    /// A slim-served row: the input and/or output is a bounded preview
    /// (PROTOCOL §5.5); expanding triggers the on-demand full fetch.
    private var isTruncated: Bool {
        block.inputTruncation.isTruncated || toolResult?.outputTruncation.isTruncated == true
    }

    private var hasError: Bool {
        toolResult?.resolvedErrorOutcome.isFailure == true
    }

    // MARK: - Tool Classification

    private var classified: ToolClassifier.ToolDisplay {
        ToolClassifier.classify(name: toolName, input: block.input)
    }

    // MARK: - Border Color (status indicator)

    private var borderColor: Color {
        if toolResult == nil { return Color.blue }
        return hasError ? Theme.destructive(for: colorScheme) : Color.green.opacity(Layout.successBorderOpacity)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: workspaceDesign ? Design.Transcript.toolRowSpacing : 0) {
            headerButton
            if isExpanded {
                expandedContent
            }
        }
        .overlay(alignment: .leading) {
            if !workspaceDesign {
                Rectangle()
                    .fill(borderColor)
                    .frame(width: Layout.statusBorderWidth)
            }
        }
    }

    private var headerButton: some View {
        Button {
            onLayoutChange?()
            withAnimation(reduceMotion ? nil : .easeInOut(duration: Layout.expansionAnimationDuration)) {
                isExpanded.toggle()
            }
            if isExpanded, isTruncated {
                onHydrate?()
            }
        } label: {
            headerLabel
                .copyContextMenuPassthrough()
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    @ViewBuilder
    private var headerLabel: some View {
        if workspaceDesign {
            HStack(alignment: .top, spacing: Design.Transcript.toolLabelSpacing) {
                toolIcon
                    .frame(width: Design.toolIconSize, height: Design.toolIconSize)
                    .accessibilityHidden(true)
                Text([classified.verb, classified.subject, classified.path].compactMap { $0 }.joined(separator: " "))
                    .interFont(Constants.Typography.bodyS)
                    .tracking(Design.Typography.bodyTracking)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                WorkspaceTranscriptDisclosure(isExpanded: isExpanded)
            }
            .foregroundStyle(inlineForeground)
            .frame(minHeight: Design.minimumTapTarget, alignment: .center)
            .contentShape(Rectangle())
        } else {
            HStack(spacing: Layout.headerSpacing) {
                toolIcon
                Text(classified.verb)
                    .interFont(Constants.Typography.subtextXXS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                if let subject = classified.subject {
                    Text(subject)
                        .interFont(Constants.Typography.subtextXXS)
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                        .lineLimit(1)
                }
                if let path = classified.path {
                    Text(path)
                        .interFont(Constants.Typography.subtextXXS)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(Layout.pathOpacity))
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: Layout.disclosureFontSize))
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme).opacity(Layout.disclosureOpacity))
                    .accessibilityHidden(true)
            }
            .padding(.leading, Layout.headerLeadingPadding)
            .padding(.vertical, Layout.headerVerticalPadding)
        }
    }

    private var toolIcon: some View {
        Image(classified.icon.rawValue)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(
                width: workspaceDesign ? Design.toolIconSize : iconSize,
                height: workspaceDesign ? Design.toolIconSize : iconSize
            )
            .foregroundStyle(workspaceDesign ? inlineForeground : Theme.mutedForeground(for: colorScheme))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: Layout.expandedContentSpacing) {
            if isTruncated {
                hydrationStatus
            }
            if workspaceDesign {
                inlineResult
                if !block.input.isEmpty {
                    DisclosureGroup("Input", isExpanded: inputExpansion) {
                        inputSection
                    }
                    .interFont(Constants.Typography.bodyXS)
                    .tint(Design.Palette.secondaryForeground(for: colorScheme, contrast: contrast))
                    .copyContextMenuPassthrough()
                }
            } else {
                if !block.input.isEmpty {
                    inputSection
                }
                if let result = toolResult {
                    resultSection(result)
                }
            }
        }
        .padding(.leading, workspaceDesign ? Design.Transcript.expandedContentIndent : Layout.expandedHorizontalPadding)
        .padding(.trailing, workspaceDesign ? 0 : Layout.expandedHorizontalPadding)
        .padding(.bottom, Layout.expandedBottomPadding)
    }

    private var inputExpansion: Binding<Bool> {
        Binding(get: { isInputExpanded }, set: { expanded in
            onLayoutChange?()
            isInputExpanded = expanded
        })
    }

    @ViewBuilder
    private var inlineResult: some View {
        if let result = toolResult {
            if let output = result.output?.value as? String {
                Text(String(output.prefix(Layout.outputCharacterLimit)))
                    .interFont(Constants.Typography.bodyS)
                    .tracking(Design.Typography.bodyTracking)
                    .foregroundStyle(hasError ? Theme.destructive(for: colorScheme)
                        : Design.Palette.secondaryForeground(for: colorScheme, contrast: contrast))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                resultSection(result)
            }
        }
    }

    private var hydrationStatus: some View {
        Button { onHydrate?() } label: {
            HStack(spacing: Layout.hydrationStatusSpacing) {
                if isHydrating {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Loading full content…")
                        .interFont(Constants.Typography.subtextXXS)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.caption2)
                        .accessibilityHidden(true)
                    Text(onHydrate != nil ? "Preview — tap to load full content" : "Preview")
                        .interFont(Constants.Typography.subtextXXS)
                }
            }
            .font(.caption2)
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .copyContextMenuPassthrough()
        }
        .buttonStyle(.plain)
        .disabled(isHydrating || onHydrate == nil)
    }

    private var inputSection: some View {
        Group {
            Text("Input")
                .interFont(Constants.Typography.subtextXXS.withFace(.semibold))
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            ScrollView(.horizontal) {
                Text(formatJSON(block.input))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.foreground(for: colorScheme))
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func resultSection(_ result: ContentBlock) -> some View {
        Divider()
        Text(hasError ? "Error" : "Result")
            .interFont(Constants.Typography.subtextXXS.withFace(.semibold))
            .foregroundStyle(hasError
                ? Theme.destructive(for: colorScheme)
                : Theme.mutedForeground(for: colorScheme))
        if let output = result.output {
            ScrollView {
                Text(String(describing: output.value).prefix(Constants.Conversation.ToolCall.outputCharacterLimit))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Constants.Conversation.ToolCall.outputMaximumHeight)
        }
    }

    private func formatJSON(_ dict: [String: AnyCodable]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict.mapValues { $0.value },
            options: [.prettyPrinted, .sortedKeys]
        ), let str = String(data: data, encoding: .utf8) else {
            return String(describing: dict)
        }
        return str
    }
}
