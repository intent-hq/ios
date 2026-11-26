import SwiftUI
import WebKit

enum InlineVisualPhase: Equatable {
    case loading
    case rendered(CGFloat)
    case failed

    var height: CGFloat? {
        guard case .rendered(let height) = self else { return nil }
        return height
    }
}

enum InlineVisualAppearance {
    static let minimumHeight: CGFloat = 96
    static let maximumInlineHeight: CGFloat = 1_600
    static let maximumStateBytes = 65_536
}

@MainActor
final class InlineVisualSessionStore {
    static let shared = InlineVisualSessionStore()
    private static let maximumEntries = 64

    private var heights: [String: CGFloat] = [:]
    private var states: [String: String] = [:]

    func height(for source: String) -> CGFloat? { heights[source] }

    func state(for source: String) -> String? { states[source] }

    func recordHeight(_ height: CGFloat, for source: String) {
        if heights[source] == nil, heights.count >= Self.maximumEntries { heights.removeAll() }
        heights[source] = height
    }

    func recordState(_ json: String, for source: String) {
        guard json.utf8.count <= InlineVisualAppearance.maximumStateBytes,
              (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)) != nil
        else { return }
        if states[source] == nil, states.count >= Self.maximumEntries { states.removeAll() }
        states[source] = json
    }
}

struct InlineVisualView: View {
    let source: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var phase = InlineVisualPhase.loading
    @State private var attempt = 0
    @ScaledMetric(relativeTo: .caption) private var controlIconSide: CGFloat = 12

    private var height: CGFloat {
        let measured = phase.height ?? InlineVisualSessionStore.shared.height(for: source)
            ?? InlineVisualAppearance.minimumHeight
        return min(max(measured, InlineVisualAppearance.minimumHeight), InlineVisualAppearance.maximumInlineHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if phase == .failed {
                Text("Unable to show this visual.")
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(MermaidAppearance.spacing)
                Divider().allowsHitTesting(false)
                retryButton
            } else {
                InlineVisualWebView(source: source, dark: colorScheme == .dark, phase: $phase)
                    .id(attempt)
                    .frame(height: height)
                    .overlay {
                        if phase == .loading {
                            ProgressView()
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
        .background(Theme.background(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: MermaidAppearance.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: MermaidAppearance.cornerRadius)
                .stroke(Theme.border(for: colorScheme), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityIdentifier("inlineVisual")
    }

    private var retryButton: some View {
        Button {
            phase = .loading
            attempt += 1
        } label: {
            Label {
                Text("Try again")
            } icon: {
                Image(.clockwiseArrow)
                    .resizable()
                    .scaledToFit()
                    .frame(width: controlIconSide, height: controlIconSide)
            }
            .frame(maxWidth: .infinity, minHeight: Constants.Accessibility.minimumTapTarget)
            .contentShape(Rectangle())
            .copyContextMenuPassthrough()
        }
        .buttonStyle(IntentContentButtonStyle())
        .interFont(Constants.Typography.bodyXS)
        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
    }
}

struct InlineVisualWebView: UIViewRepresentable {
    private static let websiteDataStore = WKWebsiteDataStore.nonPersistent()
    private static let hostWorld = WKContentWorld.world(name: "IntentInlineVisualHost")
    private static let sizeHandler = "inlineVisualSize"
    private static let stateHandler = "inlineVisualState"

    static let contentSecurityPolicy = [
        "default-src 'none'",
        "script-src 'unsafe-inline'",
        "style-src 'unsafe-inline'",
        "img-src data:",
        "connect-src 'none'",
        "font-src data:",
        "media-src 'none'",
        "object-src 'none'",
        "frame-src 'none'",
        "child-src 'none'",
        "worker-src 'none'",
        "manifest-src 'none'",
        "base-uri 'none'",
        "form-action 'none'"
    ].joined(separator: "; ")

    private static let hostStyles: String = {
        guard let url = Bundle.main.url(forResource: "InlineVisual", withExtension: "css"),
              let styles = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return styles
    }()

    let source: String
    let dark: Bool
    @Binding var phase: InlineVisualPhase

    static func document(source: String, dark: Bool) -> String {
        """
        <!doctype html><html\(dark ? " class=\"dark\"" : "")><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <meta http-equiv="x-dns-prefetch-control" content="off">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>\(hostStyles)</style></head><body>
        \(source)
        </body></html>
        """
    }

    static func bridgeScript(savedState: String?) -> String {
        """
        (() => {
          let state = \(savedState ?? "null");
          const post = (value) => window.webkit.messageHandlers.\(stateHandler).postMessage(value);
          Object.defineProperty(window, 'intentVisual', {
            configurable: false,
            writable: false,
            value: Object.freeze({
              get state() { return state; },
              publish(snapshot) {
                try {
                  if (!snapshot || typeof snapshot !== 'object') return false;
                  if (typeof snapshot.title !== 'string' || !snapshot.title.trim() || snapshot.title.length > 160) return false;
                  const encoded = JSON.stringify(snapshot);
                  if (encoded.length > \(InlineVisualAppearance.maximumStateBytes)) return false;
                  state = JSON.parse(encoded).state ?? null;
                  post(JSON.stringify(state));
                  return true;
                } catch { return false; }
              }
            })
          });
        })();
        """
    }

    static let measureScript = """
    (() => {
      let sent = -1;
      let queued = false;
      const measure = () => {
        queued = false;
        if (!document.body) return;
        const body = document.body;
        const height = Math.ceil(Math.max(body.scrollHeight, body.getBoundingClientRect().height));
        if (Math.abs(height - sent) < 1) return;
        sent = height;
        window.webkit.messageHandlers.\(sizeHandler).postMessage(height);
      };
      const schedule = () => {
        if (queued) return;
        queued = true;
        requestAnimationFrame(measure);
      };
      new ResizeObserver(schedule).observe(document.body);
      new MutationObserver(schedule).observe(document.body, { subtree: true, childList: true, attributes: true, characterData: true });
      document.fonts?.ready.then(schedule);
      measure();
    })();
    """

    func makeCoordinator() -> Coordinator { Coordinator(source: source, phase: $phase) }

    func makeUIView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.websiteDataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.dataDetectorTypes = []
        let controller = configuration.userContentController
        controller.add(coordinator, contentWorld: Self.hostWorld, name: Self.sizeHandler)
        controller.add(coordinator, contentWorld: .page, name: Self.stateHandler)
        controller.addUserScript(WKUserScript(
            source: Self.bridgeScript(savedState: InlineVisualSessionStore.shared.state(for: source)),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        ))
        controller.addUserScript(WKUserScript(
            source: Self.measureScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: Self.hostWorld
        ))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.bounces = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsLinkPreview = false
        webView.accessibilityIdentifier = "inlineVisual.webview"
        webView.overrideUserInterfaceStyle = dark ? .dark : .light
        coordinator.webView = webView
        webView.loadHTMLString(Self.document(source: source, dark: dark), baseURL: nil)
        coordinator.dark = dark
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.phase = $phase
        guard context.coordinator.dark != dark else { return }
        context.coordinator.dark = dark
        webView.overrideUserInterfaceStyle = dark ? .dark : .light
        Task {
            _ = try? await webView.callJavaScript(
                "document.documentElement.classList.toggle('dark', dark);",
                arguments: ["dark": dark],
                in: Self.hostWorld
            )
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator _: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: sizeHandler, contentWorld: hostWorld)
        controller.removeScriptMessageHandler(forName: stateHandler, contentWorld: .page)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let source: String
        var phase: Binding<InlineVisualPhase>
        var dark: Bool?
        weak var webView: WKWebView?

        init(source: String, phase: Binding<InlineVisualPhase>) {
            self.source = source
            self.phase = phase
        }

        // swiftlint:disable:next async_without_await
        func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.targetFrame?.isMainFrame == true, action.navigationType == .other,
                  action.request.url?.absoluteString == "about:blank" else { return .cancel }
            return .allow
        }

        func webView(_: WKWebView, didFail _: WKNavigation?, withError error: Error) {
            failUnlessCancelled(error)
        }

        func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation?, withError error: Error) {
            failUnlessCancelled(error)
        }

        func webViewWebContentProcessDidTerminate(_: WKWebView) {
            AppLog.userInterface.error("Inline visual web content process terminated")
            phase.wrappedValue = .failed
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame else { return }
            switch message.name {
            case InlineVisualWebView.sizeHandler:
                guard let value = message.body as? Double, value.isFinite, value > 0 else { return }
                let height = CGFloat(value)
                InlineVisualSessionStore.shared.recordHeight(height, for: source)
                webView?.scrollView.isScrollEnabled = height > InlineVisualAppearance.maximumInlineHeight
                phase.wrappedValue = .rendered(height)
            case InlineVisualWebView.stateHandler:
                guard let json = message.body as? String else { return }
                InlineVisualSessionStore.shared.recordState(json, for: source)
            default:
                return
            }
        }

        private func failUnlessCancelled(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            AppLog.userInterface.error("Inline visual load failed: \(String(describing: error))")
            phase.wrappedValue = .failed
        }
    }
}
