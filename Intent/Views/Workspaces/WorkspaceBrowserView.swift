import SwiftUI
import WebKit

struct WorkspaceBrowserView: View {
    let browser: WorkspaceBrowser
    let connection: any SessionConnectionManaging
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var page = WorkspaceBrowserPage()
    @State private var retry = UUID()

    private var isConnected: Bool { connection.connectionState == .connected }
    private var attachmentKey: String { "\(isConnected)-\(scenePhase == .background)-\(retry)" }

    var body: some View {
        NavigationStack {
            browserContent
            .background(Theme.background(for: colorScheme))
            .navigationTitle(browser.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { browserToolbar }
            .task(id: attachmentKey) {
                if isConnected, scenePhase != .background {
                    await page.open(browser, connection: connection)
                } else {
                    page.stop()
                }
            }
            .onDisappear { page.stop() }
        }
    }

    private var browserContent: some View {
        VStack(spacing: 0) {
            Text(page.address.isEmpty ? browser.url : page.address)
                .interFont(Constants.Typography.subtextXXS)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.bottom, BrowserAppearance.labelSpacing)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            if !isConnected {
                unavailable("Reconnect to your machine to open this browser.")
            } else if let errorMessage = page.errorMessage {
                unavailable(errorMessage)
            } else {
                if page.isLoading { ProgressView().padding() }
                if let webView = page.webView {
                    BrowserWebView(webView: webView)
                } else {
                    Spacer()
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var browserToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button("Back", systemImage: "chevron.left", action: page.goBack)
                .disabled(!page.canGoBack)
            Button("Forward", systemImage: "chevron.right", action: page.goForward)
                .disabled(!page.canGoForward)
            Spacer()
            Button("Reload", systemImage: "arrow.clockwise") {
                if page.errorMessage != nil || page.webView == nil {
                    retry = UUID()
                } else {
                    page.reload()
                }
            }
            .disabled(!isConnected)
        }
    }

    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView {
            Label {
                Text("Page unavailable").interFont(Constants.Typography.bodyM.withFace(.semibold))
            } icon: {
                Image(systemName: "globe")
            }
        } description: {
            Text(message).interFont(Constants.Typography.bodyS)
        } actions: {
            Button("Try again") { retry = UUID() }
                .disabled(!isConnected)
        }
    }
}

private struct BrowserWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context _: Context) -> WKWebView { webView }
    func updateUIView(_: WKWebView, context _: Context) {}
}
