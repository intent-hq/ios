import SwiftUI

struct ModelPicker: View {
    static let defaultSelectionID = ""

    let models: [ModelInfo]
    @Binding var selectedModel: ModelInfo?
    let daemonDefaultLabel: String

    var body: some View {
        Picker("Model", selection: selection) {
            Text(daemonDefaultLabel).tag(Self.defaultSelectionID)
            ForEach(models) { model in
                Text(model.name).tag(model.id)
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("creation.modelPicker")
    }

    var selection: Binding<String> {
        Binding(
            get: { selectedModel?.id ?? Self.defaultSelectionID },
            set: { id in selectedModel = models.first { $0.id == id } }
        )
    }
}
