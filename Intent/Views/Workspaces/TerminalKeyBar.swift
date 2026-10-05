import SwiftUI

struct TerminalKeyBar: View {
    let controls: MobileTerminalControls
    let isEnabled: Bool
    @State private var showsArrows = false

    var body: some View {
        VStack(spacing: TerminalAppearance.groupSpacing) {
            if showsArrows { arrowKeys }
            HStack(spacing: TerminalAppearance.groupSpacing) {
                modifierKeys
                punctuationKeys
                keyboardButton
                arrowsButton
            }
        }
        .font(.system(size: TerminalAppearance.keyFontSize, weight: .medium, design: .monospaced))
        .padding(.horizontal, TerminalAppearance.groupSpacing)
        .padding(.vertical, TerminalAppearance.groupSpacing)
        .background(TerminalAppearance.background)
    }

    private var modifierKeys: some View {
        HStack(spacing: TerminalAppearance.keySpacing) {
            textKey("esc", accessibilityLabel: "Escape", action: controls.escape)
            Button(action: controls.toggleControl) {
                Text("ctrl")
                    .frame(width: TerminalAppearance.keyWidth, height: TerminalAppearance.controlSize)
                    .background(controls.isControlEnabled ? TerminalAppearance.activeFill : .clear, in: Capsule())
            }
            .buttonStyle(TerminalControlStyle(isSelected: controls.isControlEnabled))
            .accessibilityLabel("Control")
            .accessibilityValue(controls.isControlEnabled ? "On" : "Off")
            textKey("tab", accessibilityLabel: "Tab") { controls.insert("\t") }
        }
        .padding(.horizontal, TerminalAppearance.groupInset)
        .fixedSize(horizontal: true, vertical: false)
        .modifier(TerminalControlSurface())
        .disabled(!isEnabled)
    }

    private var punctuationKeys: some View {
        ScrollView(.horizontal) {
            HStack(spacing: TerminalAppearance.keySpacing) {
                ForEach(["~", "|", "/", "-", "_", "$"], id: \.self) { symbol in
                    textKey(symbol, accessibilityLabel: symbol) { controls.insert(symbol) }
                }
            }
            .padding(.horizontal, TerminalAppearance.groupInset)
        }
        .scrollIndicators(.hidden)
        .frame(height: TerminalAppearance.controlSize)
        .modifier(TerminalControlSurface())
        .clipShape(Capsule())
        .disabled(!isEnabled)
    }

    private var keyboardButton: some View {
        Button(action: controls.toggleKeyboard) {
            Image(systemName: controls.isKeyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
                .frame(width: TerminalAppearance.controlSize, height: TerminalAppearance.controlSize)
        }
        .buttonStyle(TerminalControlStyle())
        .modifier(TerminalControlSurface())
        .accessibilityLabel(controls.isKeyboardVisible ? "Hide keyboard" : "Show keyboard")
        .disabled(!isEnabled && !controls.isKeyboardVisible)
    }

    private var arrowsButton: some View {
        Button { showsArrows.toggle() } label: {
            Image(systemName: "dpad")
                .frame(width: TerminalAppearance.controlSize, height: TerminalAppearance.controlSize)
        }
        .buttonStyle(TerminalControlStyle(isSelected: showsArrows))
        .modifier(TerminalControlSurface())
        .accessibilityLabel("Arrow keys")
        .accessibilityValue(showsArrows ? "Expanded" : "Collapsed")
    }

    private var arrowKeys: some View {
        HStack(spacing: TerminalAppearance.groupSpacing) {
            arrow(.left, image: .arrowLeft, label: "Left arrow")
            arrow(.up, image: .arrowUp, label: "Up arrow")
            arrow(.down, image: .arrowDown, label: "Down arrow")
            arrow(.right, image: .arrowRight, label: "Right arrow")
        }
        .padding(.horizontal, TerminalAppearance.groupInset)
        .modifier(TerminalControlSurface())
        .disabled(!isEnabled)
    }

    private func arrow(_ direction: MobileTerminalControls.Arrow, image: ImageResource, label: String) -> some View {
        Button { controls.arrow(direction) } label: {
            Image(image)
                .resizable()
                .scaledToFit()
                .frame(width: TerminalAppearance.keyFontSize, height: TerminalAppearance.keyFontSize)
                .frame(width: TerminalAppearance.controlSize, height: TerminalAppearance.controlSize)
        }
        .buttonStyle(TerminalControlStyle())
        .accessibilityLabel(label)
    }

    private func textKey(_ text: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .frame(width: TerminalAppearance.keyWidth, height: TerminalAppearance.controlSize)
        }
        .buttonStyle(TerminalControlStyle())
        .accessibilityLabel(accessibilityLabel)
    }
}
