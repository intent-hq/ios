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
    @State private var addressInput = ""
    @State private var targetAddress: String?
    @State private var addressError: String?
    @FocusState private var addressFocused: Bool

    private var isConnected: Bool { connection.connectionState == .connected }
    private var attachmentKey: String { "\(isConnected)-\(scenePhase == .background)-\(retry)" }

    var body: some View {
        NavigationStack {
            browserContent
            .background(Theme.background(for: colorScheme))
            .navigationTitle(page.title.isEmpty ? "Browser" : page.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { browserToolbar }
            .task(id: attachmentKey) { await attach() }
            .onAppear { addressInput = targetAddress ?? browser.url }
            .onChange(of: page.address) { _, address in
                if !address.isEmpty {
                    targetAddress = address
                    if !addressFocused { addressInput = address }
                }
            }
            .onChange(of: addressFocused) { _, focused in
                if !focused { addressInput = targetAddress ?? browser.url }
            }
            .onDisappear { page.stop() }
        }
    }

    private var browserContent: some View {
        VStack(spacing: 0) {
            addressBar
            if !isConnected {
                unavailable("Reconnect to your machine to open this browser.")
            } else if let errorMessage = page.errorMessage {
                unavailable(errorMessage)
            } else {
                if let webView = page.webView {
                    BrowserWebView(webView: webView)
                } else {
                    Spacer()
                }
            }
        }
    }

    private var addressBar: some View {
        VStack(alignment: .leading, spacing: BrowserAppearance.labelSpacing) {
            HStack(spacing: Constants.WorkspaceSearch.contentSpacing) {
                TextField("Enter a URL", text: $addressInput)
                    .interFont(Constants.Typography.bodyS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .accessibilityLabel("Browser URL")
                    .onSubmit(submitAddress)
                if page.isLoading {
                    BrowserLoadingIndicator()
                } else {
                    Image(systemName: "globe")
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Constants.WorkspaceSearch.horizontalPadding)
            .frame(minHeight: Constants.WorkspaceSearch.buttonSize)
            .background(Theme.muted(for: colorScheme), in: RoundedRectangle(cornerRadius: Constants.WorkspaceSearch.cornerRadius))
            if let addressError {
                Text(addressError).interFont(Constants.Typography.bodyXS).foregroundStyle(.red)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, BrowserAppearance.rowSpacing)
    }

    private func submitAddress() {
        do {
            targetAddress = try WorkspaceBrowserURL.normalize(addressInput)
            addressError = nil
            addressFocused = false
            retry = UUID()
        } catch {
            addressError = error.localizedDescription
        }
    }

    private func attach() async {
        guard isConnected, scenePhase != .background else { page.stop(); return }
        let address = targetAddress ?? browser.url
        if page.webView != nil, page.errorMessage == nil {
            do { try await page.navigate(to: address) } catch {
                if !Task.isCancelled { addressError = error.localizedDescription }
            }
        } else {
            let destination = WorkspaceBrowser(
                id: browser.id,
                workspaceId: browser.workspaceId,
                title: browser.title,
                url: address,
                command: browser.command
            )
            await page.open(destination, connection: connection)
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

private struct BrowserLoadingIndicator: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playback = SplashPlaybackState()
    @State private var lease: SplashAnimationLease?
    private let size: CGFloat = 24

    private var shouldAnimate: Bool {
        SplashArtView.shouldAnimate(scenePhase: scenePhase, reduceMotion: reduceMotion, hasAnimation: lease != nil)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: lease?.animation.minimumFrameDuration, paused: !shouldAnimate)) { _ in
            if let animation = lease?.animation {
                let sample = animation.frame(at: playback.elapsedTime, animated: !reduceMotion)
                SplashFrameView(animation: sample.animation, frame: sample.frame, colorScheme: colorScheme)
            } else {
                IntentLogo().fill(Theme.foreground(for: colorScheme))
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading page")
        .onAppear {
            lease = SplashAnimationStore.shared.lease()
            playback.setRunning(shouldAnimate)
        }
        .onChange(of: shouldAnimate) { _, running in playback.setRunning(running) }
        .onDisappear {
            playback.setRunning(false)
            lease = nil
        }
    }
}

private struct BrowserWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context _: Context) -> WKWebView { webView }
    func updateUIView(_: WKWebView, context _: Context) {}
}
