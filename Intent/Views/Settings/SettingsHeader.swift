import SwiftUI

struct SettingsHeader: View {
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsStyle.headerGap) {
            Button(action: onClose) {
                Label("Close Settings", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .frame(width: Constants.Accessibility.minimumTapTarget, height: Constants.Accessibility.minimumTapTarget)
                    .contentShape(.rect)
            }
            .accessibilityIdentifier("settings.close")
            Text("Settings")
                .font(.title.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
