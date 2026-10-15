import SwiftUI
import UIKit

#if DEBUG
/// Temporary, opt-in accessibility discriminator; never used by ordinary demo launches.
struct DemoIPadProducerEntry: ViewModifier {
    func body(content: Content) -> some View {
        if DemoMode.isEnabled, ProcessInfo.processInfo.arguments.contains("--demo-ipad-producer-visibility") {
            DemoIPadProducerVisibility()
        } else {
            content
        }
    }
}

private enum DemoProducerPhase: String {
    case outerHidden, outerRestored, producerHidden, producerRestored, visible

    static let sequence: [Self] = [.visible, .outerHidden, .outerRestored, .producerHidden, .producerRestored]
    var parentVisible: Bool { self != .outerHidden && self != .producerHidden }
    var directlyHidden: Bool { self == .producerHidden }
}

private struct DemoIPadProducerVisibility: View {
    private static let editorHeight: CGFloat = 100
    private static let inspectorHeight: CGFloat = 24
    @State private var phaseIndex = 0
    @State private var draft = "Keep this selected draft"
    @State private var focused = false
    @State private var inspector = DemoProducerInspector(frame: .zero)
    private var phase: DemoProducerPhase { DemoProducerPhase.sequence[phaseIndex] }

    var body: some View {
        VStack {
            HStack {
                Button("Prepare editor") { inspector.prepare() }
                    .accessibilityIdentifier("visibility.prepare")
                Button("Next phase") { phaseIndex += 1 }
                    .disabled(phaseIndex == DemoProducerPhase.sequence.count - 1)
                    .accessibilityIdentifier("visibility.next")
                Text(phase.rawValue).accessibilityIdentifier("visibility.phase")
            }
            .buttonStyle(IntentContentButtonStyle())
            Text("Standalone text")
                .accessibilityIdentifier("visibility.standalone")
                .accessibilityHidden(true, isEnabled: phase.directlyHidden)
            DemoProducerInspection(inspector: inspector, phase: phase)
                .frame(height: Self.inspectorHeight)
            HStack {
                listPane
                detailPane
            }
            .environment(\.isIPadPaneVisible, phase.parentVisible)
        }
        .padding()
        .transaction { $0.disablesAnimations = true }
    }

    private var listPane: some View {
        // Covered focus keeps the same rendered pane; only inherited visibility changes.
        RetainedIPadPane(isVisible: true, keepsCoveredContentVisible: true) {
            List {
                Section {
                    Text("List row")
                        .accessibilityIdentifier("visibility.row")
                        .accessibilityHidden(true, isEnabled: phase.directlyHidden)
                } header: {
                    Text("List header")
                        .accessibilityIdentifier("visibility.list.header")
                        .accessibilityHidden(true, isEnabled: phase.directlyHidden)
                }
            }
            .accessibilityIdentifier("visibility.list")
            .accessibilityHidden(true, isEnabled: phase.directlyHidden)
        }
        .modifier(IPadPaneBounds(identifier: "visibility.sidebar", isAccessible: phase.parentVisible))
    }

    private var detailPane: some View {
        RetainedIPadPane(isVisible: true, keepsCoveredContentVisible: true) {
            NavigationStack {
                VStack {
                    SubmittableTextView(text: $draft, isFocused: $focused) {}
                        .accessibilityHidden(true, isEnabled: phase.directlyHidden)
                        .frame(height: Self.editorHeight)
                }
                .modifier(IPadNavigationVisibility())
                .safeAreaInset(edge: .top) {
                    Text("Content header")
                        .accessibilityIdentifier("visibility.content.header")
                        .accessibilityHidden(true, isEnabled: phase.directlyHidden)
                }
            }
        }
        .modifier(IPadPaneBounds(identifier: "visibility.detail", isAccessible: phase.parentVisible))
    }
}

private struct DemoProducerInspection: UIViewRepresentable {
    let inspector: DemoProducerInspector
    let phase: DemoProducerPhase

    func makeUIView(context _: Context) -> DemoProducerInspector { inspector }
    func updateUIView(_ view: DemoProducerInspector, context _: Context) { view.phase = phase }
}

/// Reads the existing native hierarchy without rewriting its visibility or editor binding.
private final class DemoProducerInspector: UIView {
    private static let selectionLength = 4
    var phase = DemoProducerPhase.visible
    private var originalIdentity: String?
    private var originalDraft: String?
    private var originalSelection: NSRange?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityIdentifier = "visibility.native"
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func prepare() {
        let editors = editors(in: window)
        guard originalIdentity == nil, editors.count == 1, let editor = editors.first else { return }
        editor.resignFirstResponder()
        let selection = NSRange(location: 0, length: min(Self.selectionLength, editor.text.utf16.count))
        editor.selectedRange = selection
        originalIdentity = String(describing: ObjectIdentifier(editor))
        originalDraft = editor.text
        originalSelection = selection
    }

    override var accessibilityLabel: String? {
        get {
            guard originalIdentity != nil, let marker = marker(in: window?.rootViewController),
                  marker.isInteractive == phase.parentVisible,
                  marker.navigationController?.viewIfLoaded?.accessibilityElementsHidden == !phase.parentVisible,
                  marker.navigationController?.viewIfLoaded?.isUserInteractionEnabled == phase.parentVisible
            else { return "settling" }
            return phase.rawValue
        }
        set {}
    }

    override var accessibilityValue: String? {
        get {
            guard let data = try? JSONEncoder().encode(report()) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {}
    }

    private func report() -> [String: String] {
        let editors = editors(in: window)
        let editor = editors.first
        let identity = editor.map { String(describing: ObjectIdentifier($0)) } ?? "missing"
        let marker = marker(in: window?.rootViewController)
        return [
            "phase": phase.rawValue, "editorCount": String(editors.count), "editor": identity,
            "originalEditor": originalIdentity ?? "unprepared", "retained": String(identity == originalIdentity),
            "draft": editor?.text ?? "missing", "originalDraft": originalDraft ?? "unprepared",
            "selection": editor.map { NSStringFromRange($0.selectedRange) } ?? "missing",
            "originalSelection": originalSelection.map(NSStringFromRange) ?? "unprepared",
            "gateInteractive": String(marker?.isInteractive ?? false),
            "gateChildrenHidden": String(marker?.navigationController?.viewIfLoaded?.accessibilityElementsHidden ?? false)
        ]
    }

    private func editors(in view: UIView?) -> [UITextView] {
        guard let view else { return [] }
        var result: [UITextView] = []
        if let editor = view as? KeyCommandTextView, editor.accessibilityIdentifier == "composer.textView" { result.append(editor) }
        for child in view.subviews { result += editors(in: child) }
        return result
    }

    private func marker(in controller: UIViewController?) -> IPadNavigationVisibilityBridge.Controller? {
        guard let controller else { return nil }
        if let marker = controller as? IPadNavigationVisibilityBridge.Controller { return marker }
        return controller.children.lazy.compactMap { self.marker(in: $0) }.first
    }
}
#endif
