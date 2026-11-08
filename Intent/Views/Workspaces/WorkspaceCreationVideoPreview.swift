import SwiftUI

struct WorkspaceCreationVideoPreview: View {
    let file: PendingFile
    let onRemove: () -> Void
    @ScaledMetric(relativeTo: .body) private var removeIconSize: CGFloat = 17
    private let previewSide: CGFloat = 72
    private let removeTarget: CGFloat = 44
    private let placeholderOpacity = 0.2
    private let playBackgroundOpacity = 0.7

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let poster = file.video?.poster {
                    Image(uiImage: poster).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.secondary.opacity(placeholderOpacity))
                }
                Image(.play)
                    .resizable()
                    .scaledToFit()
                    .frame(width: removeIconSize, height: removeIconSize)
                    .foregroundStyle(.white)
                    .background(.black.opacity(playBackgroundOpacity), in: Circle())
            }
            .frame(width: previewSide, height: previewSide)
            .clipShape(.rect(cornerRadius: CreateWorkspaceFormStyle.rowSpacing))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Attached video: \(file.displayName)")
            Button(action: onRemove) {
                Image(.closeCircle)
                    .resizable()
                    .scaledToFit()
                    .frame(width: removeIconSize, height: removeIconSize)
                    .frame(minWidth: removeTarget, minHeight: removeTarget)
            }
            .buttonStyle(IntentContentButtonStyle())
            .accessibilityLabel("Remove video: \(file.displayName)")
            .accessibilityIdentifier("creation.removeVideo")
        }
    }
}
