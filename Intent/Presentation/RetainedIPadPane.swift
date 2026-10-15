import SwiftUI
import UIKit

struct RetainedIPadPane<Content: View>: View {
    let isVisible: Bool
    var keepsCoveredContentVisible = false
    @ViewBuilder let content: Content
    @Environment(\.isIPadPaneVisible) private var parentVisible
    @State private var inputTop: CGFloat?

    private var isInteractive: Bool { parentVisible && isVisible }

    var body: some View {
        RetainedIPadPaneHost(isInteractive: isInteractive, inputTop: $inputTop) {
            content.environment(\.isIPadPaneVisible, isInteractive)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(isVisible && (parentVisible || keepsCoveredContentVisible) ? 1 : 0)
        .allowsHitTesting(isInteractive)
        .accessibilityHidden(!isInteractive)
        .preference(key: WorkspaceActionMenuInputTop.self, value: isInteractive ? inputTop : nil)
    }
}

private struct RetainedIPadPaneHost<Content: View>: UIViewControllerRepresentable {
    let isInteractive: Bool
    @Binding var inputTop: CGFloat?
    @ViewBuilder let content: Content

    func makeUIViewController(context: Context) -> RetainedIPadPaneController {
        RetainedIPadPaneController(content: hostedContent(context: context))
    }

    func updateUIViewController(_ controller: RetainedIPadPaneController, context: Context) {
        controller.view.accessibilityElementsHidden = !isInteractive
        controller.view.isUserInteractionEnabled = isInteractive
        withTransaction(context.transaction) {
            controller.host.rootView = hostedContent(context: context)
        }
    }

    private func hostedContent(context: Context) -> AnyView {
        let inputTop = $inputTop
        return AnyView(
            content
                .environment(\.self, context.environment)
                .onPreferenceChange(WorkspaceActionMenuInputTop.self) { inputTop.wrappedValue = $0 }
        )
    }
}

/// Native navigation descendants must share the retained pane's visibility boundary.
private final class RetainedIPadPaneController: UIViewController {
    let host: UIHostingController<AnyView>

    init(content: AnyView) {
        host = UIHostingController(rootView: content)
        super.init(nibName: nil, bundle: nil)
        // The outer shell already applies the window and keyboard safe areas.
        host.safeAreaRegions = []
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        addChild(host)
        host.view.backgroundColor = .clear
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

/// The resized pane owns its interaction and accessibility bounds. Native lists
/// and navigation containers otherwise report their enclosing window's frame.
struct IPadPaneBounds: ViewModifier {
    let identifier: String
    let isAccessible: Bool

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
            .contentShape([.interaction, .accessibility], Rectangle())
            .accessibilityHidden(!isAccessible)
    }
}
