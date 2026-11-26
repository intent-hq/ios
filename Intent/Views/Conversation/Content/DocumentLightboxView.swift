import QuickLook
import SwiftUI

struct DocumentLightboxView: View {
    let document: WorkspaceDocument
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            DocumentQuickLookView(url: document.url)
                .ignoresSafeArea(edges: .bottom)
                .accessibilityIdentifier("document.viewer")
                .navigationTitle(document.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        IntentIconButton(icon: .close, label: "Close file") { dismiss() }
                            .accessibilityIdentifier("document.close")
                    }
                    .intentToolbarSurface()
                    ToolbarItem(placement: .primaryAction) {
                        shareLink
                    }
                    .intentToolbarSurface()
                }
                .accessibilityAction(.escape) { dismiss() }
        }
    }

    private var shareLink: some View {
        ShareLink(item: document.url) {
            Image(.upload)
                .resizable()
                .scaledToFit()
                .frame(width: WorkspaceDetailStyle.iconSize, height: WorkspaceDetailStyle.iconSize)
                .foregroundStyle(Constants.Pairing.foreground(for: colorScheme))
                .frame(width: WorkspaceDetailStyle.controlSize, height: WorkspaceDetailStyle.controlSize)
                .background { WorkspaceControlSurface() }
                .contentShape(.rect(cornerRadius: Constants.WorkspaceSearch.cornerRadius))
                .accessibilityHidden(true)
                .visionHoverShape(.rect(cornerRadius: Constants.WorkspaceSearch.cornerRadius))
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel("Share file")
        .accessibilityIdentifier("document.share")
    }
}

struct DocumentQuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in _: QLPreviewController) -> Int { 1 }

        func previewController(_: QLPreviewController, previewItemAt _: Int) -> any QLPreviewItem {
            url as QLPreviewItem
        }
    }
}
