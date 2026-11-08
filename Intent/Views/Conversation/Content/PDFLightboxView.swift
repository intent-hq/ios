import PDFKit
import SwiftUI

struct PDFLightboxView: View {
    /// Retain the file independently of the transcript attachment/cache.
    let pdf: WorkspacePDF
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var closeIconSide: CGFloat = 17

    var body: some View {
        NavigationStack {
            WorkspacePDFView(pdf: pdf)
                .navigationTitle(pdf.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        closeButton
                    }
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: pdf.shareURL) {
                            Label {
                                Text("Share PDF")
                            } icon: {
                                Image(.upload)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: closeIconSide, height: closeIconSide)
                            }
                        }
                        .buttonStyle(IntentContentButtonStyle())
                    }
                }
                .accessibilityAction(.escape) { dismiss() }
        }
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(.close)
                .resizable()
                .scaledToFit()
                .frame(width: closeIconSide, height: closeIconSide)
                .foregroundStyle(.white)
                .padding(Constants.Conversation.ImageLightbox.actionButtonPadding)
                .background(.black, in: Circle())
                .frame(
                    minWidth: Constants.Accessibility.minimumTapTarget,
                    minHeight: Constants.Accessibility.minimumTapTarget
                )
                .contentShape(.rect)
                .accessibilityHidden(true)
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel("Close PDF")
        .accessibilityIdentifier("pdf.close")
    }
}

/// PDFView supplies native continuous scrolling, text accessibility, and pinch zoom.
struct WorkspacePDFView: UIViewRepresentable {
    let pdf: WorkspacePDF

    func makeUIView(context _: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = try? WorkspacePDF.openDocument(at: pdf.url)
        view.autoScales = true
        view.accessibilityLabel = String(localized: "PDF viewer: \(pdf.name), \(pdf.pageCount) pages")
        return view
    }

    func updateUIView(_ view: PDFView, context _: Context) {
        guard view.document?.documentURL != pdf.url else { return }
        view.document = try? WorkspacePDF.openDocument(at: pdf.url)
        view.autoScales = true
        view.accessibilityLabel = String(localized: "PDF viewer: \(pdf.name), \(pdf.pageCount) pages")
    }
}
