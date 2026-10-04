import SwiftUI

enum MermaidAppearance {
    static let minimumHeight: CGFloat = 100
    static let maximumInlineHeight: CGFloat = 360
    static let cornerRadius: CGFloat = 8
    static let spacing: CGFloat = 8
    static let renderTimeout: Duration = .seconds(20)
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
    @State private var showsSource = false
    @State private var retry = UUID()

    private var inlineHeight: CGFloat {
        min(max(state.height ?? MermaidAppearance.minimumHeight, MermaidAppearance.minimumHeight), MermaidAppearance.maximumInlineHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsSource || state.error != nil {
                sourceView
            }
            MermaidWebView(source: source, dark: colorScheme == .dark, expanded: expanded, state: $state)
                .id(retry)
                .frame(height: state.error != nil ? 0 : expanded ? nil : inlineHeight)
                .frame(maxHeight: expanded && state.error == nil ? .infinity : nil)
                .overlay {
                    if state.isLoading {
                        ProgressView("Drawing diagram")
                            .interFont(Constants.Typography.bodyXS)
                    }
                }
                .accessibilityHidden(state.isLoading || state.error != nil)
            controls
        }
        .background(Theme.background(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: MermaidAppearance.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: MermaidAppearance.cornerRadius)
                .stroke(Theme.border(for: colorScheme), lineWidth: 1)
        }
    }

    private var sourceView: some View {
        VStack(alignment: .leading, spacing: MermaidAppearance.spacing) {
            if let error = state.error {
                Text(error)
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }
            ScrollView([.horizontal, .vertical]) {
                Text(source)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: MermaidAppearance.maximumInlineHeight)
            .accessibilityLabel("Diagram source")
        }
        .padding(MermaidAppearance.spacing)
    }

    private var controls: some View {
        HStack(spacing: MermaidAppearance.spacing) {
            Button(showsSource ? "Hide source" : "View source", systemImage: "chevron.left.forwardslash.chevron.right") {
                showsSource.toggle()
            }
            .disabled(state.error != nil)
            Spacer(minLength: 0)
            if state.error != nil {
                Button("Try again", systemImage: "arrow.clockwise") {
                    state = .loading
                    retry = UUID()
                }
            }
            if let onExpand {
                Button("Expand diagram", systemImage: "arrow.up.left.and.arrow.down.right", action: onExpand)
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Expand diagram")
            }
        }
        .buttonStyle(.borderless)
        .interFont(Constants.Typography.bodyXS)
        .frame(minHeight: Constants.Accessibility.minimumTapTarget)
        .padding(.horizontal, MermaidAppearance.spacing)
        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
    }
}
