import SwiftUI

/// The label owns enabled/disabled colors; don't apply PlainButtonStyle's extra
/// disabled dimming on top of the explicit Figma disabled palette.
struct ConnectionSheetButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? Constants.ConnectionSheet.pressedOpacity : 1)
    }
}
