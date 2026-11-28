import Photos
import SwiftUI
import UniformTypeIdentifiers

enum ImageInfoFormat {
    static func dimensionsText(for image: UIImage) -> String {
        dimensionsText(
            pixelWidth: Int((image.size.width * image.scale).rounded()),
            pixelHeight: Int((image.size.height * image.scale).rounded())
        )
    }

    static func dimensionsText(pixelWidth: Int, pixelHeight: Int) -> String {
        "\(pixelWidth) × \(pixelHeight)"
    }

    static func byteCountText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

enum ChatImageSaveOutcome: Equatable {
    case denied
    case failed
    case saved

    var failureMessage: String? {
        switch self {
        case .denied: "Allow Intent to add photos in Settings to save this image."
        case .failed: "Couldn’t save this image. Try again."
        case .saved: nil
        }
    }
}

enum ChatImageSaver {
    static func save(_ image: UIImage) async -> ChatImageSaveOutcome {
        await save(
            image,
            requestAuthorization: { await PHPhotoLibrary.requestAuthorization(for: .addOnly) },
            write: { image in
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
            }
        )
    }

    static func save(
        _ image: UIImage,
        requestAuthorization: () async -> PHAuthorizationStatus,
        write: (UIImage) async throws -> Void
    ) async -> ChatImageSaveOutcome {
        switch await requestAuthorization() {
        case .authorized, .limited:
            break
        case .denied, .restricted:
            return .denied
        default:
            return .failed
        }
        do {
            try await write(image)
            return .saved
        } catch {
            return .failed
        }
    }
}

@Observable final class ImageSaveAlertModel {
    struct Failure: Identifiable {
        let id = UUID()
        let image: UIImage
        let outcome: ChatImageSaveOutcome
    }

    var failure: Failure?
    @ObservationIgnored var saveImage: (UIImage) async -> ChatImageSaveOutcome = { await ChatImageSaver.save($0) }

    func save(_ image: UIImage) async {
        let outcome = await saveImage(image)
        HapticManager.notification(outcome == .saved ? .success : .error)
        failure = outcome == .saved ? nil : Failure(image: image, outcome: outcome)
    }
}

private struct ImageSaveAlertModifier: ViewModifier {
    @State private var model = ImageSaveAlertModel()
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
            .environment(model)
            .alert(
                "Couldn’t Save Image",
                isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } }),
                presenting: model.failure
            ) { failure in
                if failure.outcome == .denied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                } else {
                    Button("Try Again") {
                        Task { await model.save(failure.image) }
                    }
                }
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text(failure.outcome.failureMessage ?? "")
            }
    }
}

extension View {
    func imageSaveAlert() -> some View { modifier(ImageSaveAlertModifier()) }
}

struct ImageActionMenuItems: View {
    let image: UIImage
    var originalData: Data?
    @Environment(ImageSaveAlertModel.self) private var saveAlert: ImageSaveAlertModel?

    var body: some View {
        Button {
            Task { [image, saveAlert] in
                if let saveAlert {
                    await saveAlert.save(image)
                } else {
                    let outcome = await ChatImageSaver.save(image)
                    HapticManager.notification(outcome == .saved ? .success : .error)
                }
            }
        } label: {
            Label("Save Image", image: "Download")
        }
        Button {
            UIPasteboard.general.image = image
            HapticManager.notification(.success)
        } label: {
            Label("Copy Image", image: "Copy")
        }
        let shareImage = ShareableChatImage(image: image)
        ShareLink(item: shareImage, preview: SharePreview("Image", image: shareImage)) {
            Label("Share Image", image: "Upload")
        }
        Section {
            Text(ImageInfoFormat.dimensionsText(for: image))
            if let bytes = originalData?.count ?? image.pngData()?.count {
                Text(ImageInfoFormat.byteCountText(bytes))
            }
        }
    }
}

struct InlineImageThumbnail: View {
    let image: UIImage
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let size = Self.size(for: image.size)
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: size.width, height: size.height)
            .accessibilityLabel("Attached image")
            .clipShape(.rect(cornerRadius: Constants.Conversation.ImageThumbnail.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Constants.Conversation.ImageThumbnail.cornerRadius)
                    .strokeBorder(Theme.border(for: colorScheme), lineWidth: Constants.Conversation.ImageThumbnail.borderWidth)
            }
    }

    nonisolated static func size(for imageSize: CGSize, proposedWidth: CGFloat? = nil) -> CGSize {
        let limit = Constants.Conversation.ImageThumbnail.transcriptSide
        let width = max(0, min(limit, proposedWidth ?? limit))
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: width, height: width)
        }
        let scale = min(width / imageSize.width, limit / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}

struct SquareImageThumbnail: View {
    let image: UIImage
    let side: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    nonisolated static let transcriptSide: CGFloat = Constants.Conversation.ImageThumbnail.transcriptSide

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .accessibilityLabel("Attached image")
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: Constants.Conversation.ImageThumbnail.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Constants.Conversation.ImageThumbnail.cornerRadius)
                    .strokeBorder(
                        Theme.border(for: colorScheme),
                        lineWidth: Constants.Conversation.ImageThumbnail.borderWidth
                    )
            )
    }
}

struct ShareableChatImage: Transferable {
    let image: UIImage

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { shareable in
            await MainActor.run { shareable.image.pngData() } ?? Data()
        }
    }
}

enum ChatAttachmentPasteboard {
    struct Contents: Sendable {
        let data: Data
        let typeIdentifier: String
    }

    @concurrent
    static func contents(of url: URL) async -> Contents? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        return Contents(data: data, typeIdentifier: type.identifier)
    }

    static func copyFile(at url: URL, to pasteboard: UIPasteboard = .general) async -> Bool {
        guard let contents = await contents(of: url) else { return false }
        pasteboard.setData(contents.data, forPasteboardType: contents.typeIdentifier)
        return true
    }
}

struct VideoShareLink<Label: View>: View {
    let video: WorkspaceVideo
    let name: String
    @ViewBuilder let label: () -> Label

    var body: some View {
        ShareLink(item: (try? video.shareFile(named: name)) ?? video.url, label: label)
    }
}

struct VideoAttachmentActionMenuItems: View {
    let video: WorkspaceVideo
    let name: String

    var body: some View {
        AttachmentCopyButton(url: video.url, title: "Copy Video")
        VideoShareLink(video: video, name: name) {
            Label("Share Video", image: "Upload")
        }
    }
}

struct PDFAttachmentActionMenuItems: View {
    let pdf: WorkspacePDF

    var body: some View {
        AttachmentCopyButton(url: pdf.shareURL, title: "Copy PDF")
        ShareLink(item: pdf.shareURL) {
            Label("Share PDF", image: "Upload")
        }
    }
}

private struct AttachmentCopyButton: View {
    let url: URL
    let title: LocalizedStringKey

    var body: some View {
        Button {
            Task { [url] in
                let copied = await ChatAttachmentPasteboard.copyFile(at: url)
                HapticManager.notification(copied ? .success : .error)
            }
        } label: {
            Label(title, image: "Copy")
        }
    }
}
