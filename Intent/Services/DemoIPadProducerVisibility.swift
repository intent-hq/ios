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
    private static let overflowRowCount = 80
    @State private var phaseIndex = 0
    @State private var actionCount = 0
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
            Text("List actions: \(actionCount)")
                .accessibilityIdentifier("visibility.action.count")
            DemoProducerInspection(inspector: inspector, phase: phase, actionCount: actionCount)
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
                    Button("Activate List action") { actionCount += 1 }
                        .buttonStyle(IntentContentButtonStyle())
                        .accessibilityIdentifier("visibility.action")
                        .accessibilityHidden(true, isEnabled: phase.directlyHidden)
                    ForEach(0..<Self.overflowRowCount, id: \.self) { index in
                        Text("Overflow row \(index)")
                            .accessibilityHidden(true, isEnabled: phase.directlyHidden)
                    }
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
    let actionCount: Int

    func makeUIView(context _: Context) -> DemoProducerInspector { inspector }
    func updateUIView(_ view: DemoProducerInspector, context _: Context) {
        view.phase = phase
        view.actionCount = actionCount
    }
}

/// Reads the existing native hierarchy without rewriting its visibility or editor binding.
private final class DemoProducerInspector: UIView {
    private static let selectionLength = 4
    var phase = DemoProducerPhase.visible
    var actionCount = 0
    private var originalIdentity: String?
    private var originalListIdentity: String?
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
        let lists = lists(in: window)
        guard originalIdentity == nil, editors.count == 1, let editor = editors.first,
              lists.count == 1, let list = lists.first else { return }
        editor.resignFirstResponder()
        let selection = NSRange(location: 0, length: min(Self.selectionLength, editor.text.utf16.count))
        editor.selectedRange = selection
        originalIdentity = String(describing: ObjectIdentifier(editor))
        originalListIdentity = String(describing: ObjectIdentifier(list))
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
        let editorReport = [
            "phase": phase.rawValue, "editorCount": String(editors.count), "editor": identity,
            "originalEditor": originalIdentity ?? "unprepared", "retained": String(identity == originalIdentity),
            "draft": editor?.text ?? "missing", "originalDraft": originalDraft ?? "unprepared",
            "selection": editor.map { NSStringFromRange($0.selectedRange) } ?? "missing",
            "originalSelection": originalSelection.map(NSStringFromRange) ?? "unprepared",
            "gateInteractive": String(marker?.isInteractive ?? false),
            "gateChildrenHidden": String(marker?.navigationController?.viewIfLoaded?.accessibilityElementsHidden ?? false)
        ]
        return editorReport.merging(listReport()) { current, _ in current }
    }

    private func listReport() -> [String: String] {
        let lists = lists(in: window)
        var report = ["listCount": String(lists.count), "actionCount": String(actionCount)]
        guard lists.count == 1, let list = lists.first else { return report }
        report["list"] = String(describing: ObjectIdentifier(list))
        report["originalList"] = originalListIdentity ?? "unprepared"
        report["listOffsetX"] = String(Double(list.contentOffset.x))
        report["listOffsetY"] = String(Double(list.contentOffset.y))
        report["listMinimumY"] = String(Double(-list.adjustedContentInset.top))
        report["listMaximumY"] = String(Double(max(-list.adjustedContentInset.top, list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)))
        report["listHeight"] = String(Double(list.bounds.height))
        report["listIdle"] = String(!list.isTracking && !list.isDragging && !list.isDecelerating)
        return report
    }

    private func lists(in view: UIView?) -> [UICollectionView] {
        guard let view else { return [] }
        var result: [UICollectionView] = []
        if let list = view as? UICollectionView { result.append(list) }
        for child in view.subviews { result += lists(in: child) }
        return result
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
