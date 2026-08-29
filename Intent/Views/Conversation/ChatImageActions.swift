import Photos
import SwiftUI

/// Formatting helpers for the chat-image action menus' non-interactive
/// info rows (dimensions + file size).
enum ImageInfoFormat {
    /// Pixel dimensions as "W × H". `UIImage.size` is in points; `scale`
    /// converts to pixels (base64-decoded images have scale 1).
    static func dimensionsText(for image: UIImage) -> String {
        dimensionsText(
            pixelWidth: Int((image.size.width * image.scale).rounded()),
            pixelHeight: Int((image.size.height * image.scale).rounded()))
    }

    static func dimensionsText(pixelWidth: Int, pixelHeight: Int) -> String {
        "\(pixelWidth) × \(pixelHeight)"
    }

    /// Localized file-size string (e.g. "1.2 MB").
    static func byteCountText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Saves a chat image to the user's photo library with add-only access
/// (pairs with `NSPhotoLibraryAddUsageDescription` in Info.plist).
enum ChatImageSaver {
    static func save(_ image: UIImage) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            return true
        } catch {
            return false
        }
    }
}

/// Shared Save Image / Copy Image actions + info rows used by both the
/// thumbnail long-press context menu and the lightbox ellipsis menu
/// (FE parity: the chat-image ellipsis menu; iOS offers Save/Copy in place
/// of Download/Copy path).
struct ImageActionMenuItems: View {
    let image: UIImage
    /// Original encoded bytes when known (base64 image blocks); the size
    /// row falls back to a PNG re-encode of the loaded image when absent.
    var originalData: Data? = nil

    var body: some View {
        Button {
            Task { [image] in
                let saved = await ChatImageSaver.save(image)
                HapticManager.notification(saved ? .success : .error)
            }
        } label: {
            Label("Save Image", systemImage: "square.and.arrow.down")
        }
        Button {
            UIPasteboard.general.image = image
            HapticManager.notification(.success)
        } label: {
            Label("Copy Image", systemImage: "doc.on.doc")
        }
        Section {
            Text(ImageInfoFormat.dimensionsText(for: image))
            if let bytes = originalData?.count ?? image.pngData()?.count {
                Text(ImageInfoFormat.byteCountText(bytes))
            }
        }
    }
}

/// Fixed square, cropped, bordered, rounded chat-image thumbnail (FE
/// parity: ChatImageBlock.svelte square thumbnails; user-row attachments
/// keep their smaller side).
struct SquareImageThumbnail: View {
    let image: UIImage
    let side: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    /// Assistant transcript thumbnails (agent image blocks + markdown
    /// images) — FE parity: 160px.
    static let transcriptSide: CGFloat = 160

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.border(for: colorScheme), lineWidth: 0.5)
            )
    }
}
