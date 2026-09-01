import SwiftUI

struct ToastView: View {
    let toast: ToastInfo
    var onTap: () -> Void
    var onDismiss: () -> Void

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        HStack(spacing: Constants.Toast.contentSpacing) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: Constants.Toast.textSpacing) {
                Text(toast.agentName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(toast.workspaceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text("Done")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Constants.Toast.horizontalPadding)
        .padding(.vertical, Constants.Toast.verticalPadding)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Constants.Toast.cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(Constants.Toast.shadowOpacity),
                radius: Constants.Toast.shadowRadius, x: 0, y: Constants.Toast.shadowYOffset)
        .padding(.horizontal, Constants.Toast.outerHorizontalPadding)
        .offset(y: min(dragOffset, 0)) // Only allow upward drag
        .gesture(
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
                            dampingFraction: Constants.Toast.resetSpringDamping)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .onTapGesture {
            onTap()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

