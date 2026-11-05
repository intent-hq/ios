import SwiftUI
import WebKit

struct WorkspaceBrowserView: View {
    @ScaledMetric(relativeTo: .title) private var emptyStateIconSize: CGFloat = 48
    let browser: WorkspaceBrowser
    let connection: any SessionConnectionManaging
    var onClose: (() -> Void)?
    var onPageChange: (String, String) -> Void = { _, _ in }
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
            .safeAreaInset(edge: .top, spacing: 0) {
                if let onClose { mainContentHeader(onClose: onClose) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                addressBar
                    .padding(.top, BrowserAppearance.rowSpacing)
                    .background(WorkspaceDetailStyle.background(for: colorScheme))
                    .keepsReadOnlyPillAbove()
            }
            .background(WorkspaceDetailStyle.background(for: colorScheme))
            .navigationTitle(page.title.isEmpty ? "Browser" : page.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { browserToolbar }
            .toolbar(onClose == nil ? .automatic : .hidden, for: .navigationBar)
            .task(id: attachmentKey) { await attach() }
            .onAppear { addressInput = targetAddress ?? browser.url }
            .onChange(of: browser.url) { _, url in updateRequestedURL(url) }
            .onChange(of: page.title) { _, title in onPageChange(page.address, title) }
            .onChange(of: page.address) { _, address in
                onPageChange(address, page.title)
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

    private func updateRequestedURL(_ url: String) {
        targetAddress = url
        addressInput = url
        retry = UUID()
    }

    private var browserContent: some View {
        VStack(spacing: 0) {
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
            HStack(spacing: BrowserAppearance.labelSpacing) {
                navigationButton("Back", icon: .chevronLeft, isEnabled: page.canGoBack, action: page.goBack)
                navigationButton("Forward", icon: .chevronRight, isEnabled: page.canGoForward, action: page.goForward)
                TextField("Enter a URL", text: $addressInput)
                    .interFont(Constants.Typography.bodyS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .accessibilityLabel("Browser URL")
                    .onSubmit(submitAddress)
                    .frame(minWidth: 0, maxWidth: .infinity)
                if page.isLoading {
                    IntentLoadingIndicator(label: "Loading page")
                }
                navigationButton("Reload", icon: .clockwiseArrow, isEnabled: isConnected, action: reloadPage)
            }
            .padding(.horizontal, BrowserAppearance.labelSpacing)
            .frame(minHeight: Constants.WorkspaceSearch.buttonSize)
            .background(Theme.muted(for: colorScheme), in: RoundedRectangle(cornerRadius: Constants.WorkspaceSearch.cornerRadius))
            if let addressError {
                Text(addressError).interFont(Constants.Typography.bodyXS).foregroundStyle(.red)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, BrowserAppearance.rowSpacing)
    }

    private func navigationButton(_ title: String, icon: ImageResource, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(icon)
                .resizable()
                .scaledToFit()
                .frame(width: WorkspaceDetailStyle.iconSize, height: WorkspaceDetailStyle.iconSize)
                .foregroundStyle(isEnabled
                    ? Theme.foreground(for: colorScheme)
                    : CreateWorkspaceFormStyle.disabledForeground(for: colorScheme))
                .frame(width: BrowserAppearance.controlSize, height: BrowserAppearance.controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel(title)
        .disabled(!isEnabled)
    }

    private func reloadPage() {
        if page.errorMessage != nil || page.webView == nil {
            retry = UUID()
        } else {
            page.reload()
        }
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
        if onClose == nil {
            ToolbarItem(placement: .cancellationAction) {
                IntentIconButton(icon: .close, label: "Done") { dismiss() }
            }
            .intentToolbarSurface()
        }
    }

    private func mainContentHeader(onClose: @escaping () -> Void) -> some View {
        WorkspaceNavigationHeader(
            title: page.title.isEmpty ? "Browser" : page.title,
            subtitle: nil,
            backLabel: "Close main browser",
            backIdentifier: "browser.main.close",
            titleIdentifier: "browser.main.title",
            leadingIcon: .close,
            usesConversationLayout: true,
            onBack: onClose
        ) {
            Color.clear
                .frame(width: Constants.Conversation.Design.Header.controlSize, height: Constants.Conversation.Design.Header.controlSize)
                .accessibilityHidden(true)
        }
    }

    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView {
            Label {
                Text("Page unavailable").interFont(Constants.Typography.bodyM.withFace(.semibold))
            } icon: {
                Image(.globe)
                    .resizable()
                    .scaledToFit()
                    .frame(width: emptyStateIconSize, height: emptyStateIconSize)
            }
        } description: {
            Text(message).interFont(Constants.Typography.bodyS)
        } actions: {
            Button("Try again") { retry = UUID() }
                .buttonStyle(IntentButtonStyle(variant: .secondary))
                .disabled(!isConnected)
        }
    }
}

private struct BrowserWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context _: Context) -> WKWebView { webView }
    func updateUIView(_: WKWebView, context _: Context) {}
}
