import SwiftUI

struct CreateWorkspaceSourceCard: View {
    let repositoryFullName: String
    let branch: String
    let onEdit: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.legibilityWeight) private var legibilityWeight
    @ScaledMetric(relativeTo: .body) private var textSize = Constants.Typography.bodySEmphasized.size
    @ScaledMetric(relativeTo: .body) private var textTracking = CreateWorkspaceFormStyle.bodyTracking
    @ScaledMetric(relativeTo: .callout) private var folderSize: CGFloat = 20
    @ScaledMetric(relativeTo: .caption) private var chevronSize: CGFloat = 16

    var body: some View {
        Button(action: onEdit) {
            HStack(alignment: .top, spacing: CreateWorkspaceFormStyle.controlPadding) {
                folderIcon
                VStack(alignment: .leading, spacing: CreateWorkspaceFormStyle.rowSpacing) {
                    trimmedText(Text(repositoryFullName))
                    trimmedText(Text("off branch \(Text(branch).foregroundStyle(CreateWorkspaceFormStyle.foreground(for: colorScheme)))"))
                        .foregroundStyle(CreateWorkspaceFormStyle.secondary(for: colorScheme, contrast: contrast))
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(.chevronRight)
                    .resizable()
                    .scaledToFit()
                    .frame(width: chevronSize, height: chevronSize)
                    .accessibilityHidden(true)
            }
            .font(.callout)
            .foregroundStyle(CreateWorkspaceFormStyle.foreground(for: colorScheme))
            .multilineTextAlignment(.leading)
            .padding(CreateWorkspaceFormStyle.pagePadding)
            .frame(minHeight: CreateWorkspaceFormStyle.sourceHeight)
            .background(CreateWorkspaceFormStyle.card(for: colorScheme), in: .rect(
                cornerRadius: CreateWorkspaceFormStyle.cornerRadius
            ))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("creation.sourceCard")
        .accessibilityLabel("Source. Repository: \(repositoryFullName). Branch: \(branch)")
        .accessibilityHint("Change the branch, or go back again to change the repository.")
    }

    private func trimmedText(_ text: Text) -> some View {
        let style = Constants.Typography.bodySEmphasized
        let face = legibilityWeight == .bold ? style.face.legibleFace : style.face
        let font = CTFontCreateWithName(face.rawValue as CFString, textSize, nil)
        return WorkspaceTextTrimLayout(capHeight: CTFontGetCapHeight(font)) {
            text
                .interFont(style)
                .tracking(textTracking)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var folderIcon: some View {
        Image(.folder)
            .resizable()
            .scaledToFit()
            .frame(width: folderSize, height: folderSize)
            .foregroundStyle(CreateWorkspaceFormStyle.secondary(for: colorScheme, contrast: contrast))
            .accessibilityHidden(true)
    }
}
