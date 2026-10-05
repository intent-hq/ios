import SwiftUI

enum MermaidAppearance {
    static let minimumHeight: CGFloat = 100
    static let maximumInlineHeight: CGFloat = 360
    static let cornerRadius: CGFloat = 8
    static let spacing: CGFloat = 8
    private static let renderTimeoutSeconds = 20
    static let renderTimeout: Duration = .seconds(renderTimeoutSeconds)
}

struct MermaidDiagramView: View {
    let source: String
    @State private var isExpanded = false

    var body: some View {
        MermaidCanvas(source: source, expanded: false) {
            isExpanded = true
        }
        .fullScreenCover(isPresented: $isExpanded) {
            MermaidExpandedView(source: source)
        }
    }
}

struct MermaidStreamingPlaceholder: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ProgressView("Generating diagram")
            .interFont(Constants.Typography.bodyXS)
            .frame(maxWidth: .infinity, minHeight: MermaidAppearance.minimumHeight)
            .background(Theme.background(for: colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: MermaidAppearance.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: MermaidAppearance.cornerRadius)
                    .stroke(Theme.border(for: colorScheme), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("mermaid.streaming")
    }
}

private struct MermaidExpandedView: View {
    let source: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MermaidCanvas(source: source, expanded: true)
                .navigationTitle("Diagram")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("mermaid.done")
                    }
                }
        }
    }
}

private struct MermaidCanvas: View {
    let source: String
    let expanded: Bool
    var onExpand: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @State private var state = MermaidRenderState.loading
    @State private var retry = UUID()

    private var inlineHeight: CGFloat {
        min(max(state.height ?? MermaidAppearance.minimumHeight, MermaidAppearance.minimumHeight), MermaidAppearance.maximumInlineHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = state.error {
                Text(error)
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(MermaidAppearance.spacing)
            } else {
                diagram
            }
            if state.error != nil || onExpand != nil {
                Divider().allowsHitTesting(false)
                controls
                    .buttonStyle(.plain)
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }
        }
        .background(Theme.background(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: MermaidAppearance.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: MermaidAppearance.cornerRadius)
                .stroke(Theme.border(for: colorScheme), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var diagram: some View {
        MermaidWebView(source: source, dark: colorScheme == .dark, expanded: expanded, state: $state)
            .id(retry)
            .frame(height: expanded ? nil : inlineHeight)
            .frame(maxHeight: expanded ? .infinity : nil)
            .overlay {
                if state.isLoading {
                    ProgressView("Drawing diagram")
                        .interFont(Constants.Typography.bodyXS)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityHidden(state.isLoading)
    }

    @ViewBuilder
    private var controls: some View {
        if state.error != nil {
            Button {
                state = .loading
                retry = UUID()
            } label: {
                controlLabel("Try again", systemImage: "arrow.clockwise")
            }
        } else if let onExpand {
            Button(action: onExpand) {
                controlLabel("Full screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityIdentifier("mermaid.expand")
        }
    }

    private func controlLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, minHeight: Constants.Accessibility.minimumTapTarget)
            .contentShape(Rectangle())
            .copyContextMenuPassthrough()
    }
}
