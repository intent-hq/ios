import SwiftUI

struct ModelPicker: View {
    static let defaultSelectionID = ""

    let models: [ModelInfo]
    @Binding var selectedModel: ModelInfo?
    let daemonDefaultLabel: String

    var body: some View {
        Picker(selection: selection) {
            Text(daemonDefaultLabel).interFont(Constants.Typography.bodyS).tag(Self.defaultSelectionID)
            ForEach(models) { model in
                Text(model.name).interFont(Constants.Typography.bodyS).tag(model.id)
            }
        } label: {
            Text("Model").interFont(Constants.Typography.bodyS)
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
