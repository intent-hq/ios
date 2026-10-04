import SwiftUI

struct ToastView: View {
    let toast: ToastInfo
    var onTap: () -> Void
    var onDismiss: () -> Void

    @State private var dragOffset: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Constants.Toast.contentSpacing) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Constants.Pairing.onAccent, Constants.Pairing.accent)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Constants.Toast.textSpacing) {
                    Text(toast.workspaceName)
                        .interFont(Constants.Typography.bodyXS.withFace(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)

                    Text(toast.agentName)
                        .interFont(Constants.Typography.subtextXXS)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }

                Spacer()

                Text("Done")
                    .interFont(Constants.Typography.subtextXXS.withFace(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Constants.Toast.horizontalPadding)
            .padding(.vertical, Constants.Toast.verticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Constants.Toast.cornerRadius, style: .continuous))
        .shadow(
            color: .black.opacity(Constants.Toast.shadowOpacity),
            radius: Constants.Toast.shadowRadius,
            x: 0,
            y: Constants.Toast.shadowYOffset
        )
        .padding(.horizontal, Constants.Toast.outerHorizontalPadding)
        .offset(y: min(dragOffset, 0)) // Only allow upward drag
        .highPriorityGesture(
            DragGesture()
                .onChanged { value in
                    dragOffset = value.translation.height
                }
                .onEnded { value in
                    if value.translation.height < Constants.Toast.dismissalDragThreshold {
                        onDismiss()
                    } else {
                        withAnimation(.spring(
                            response: Constants.Toast.resetSpringResponse,
                            dampingFraction: Constants.Toast.resetSpringDamping
                        )) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .accessibilityLabel("\(toast.workspaceName): \(toast.agentName) completed")
        .accessibilityHint("Opens the completed conversation")
        .accessibilityAction(named: "Dismiss") {
            onDismiss()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
