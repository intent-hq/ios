import SwiftUI

struct ModelPicker: View {
    static let defaultSelectionID = ""

    let models: [ModelInfo]
    @Binding var selectedModel: ModelInfo?
    let daemonDefaultLabel: String
    var usesFormStyle = false

    var body: some View {
        Group {
            if usesFormStyle {
                Menu {
                    picker.pickerStyle(.inline)
                } label: {
                    CreateWorkspaceChoiceLabel(title: selectedModel?.name ?? daemonDefaultLabel)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Model")
                .accessibilityValue(selectedModel?.name ?? daemonDefaultLabel)
                .accessibilityIdentifier("creation.modelPicker")
            } else {
                picker.pickerStyle(.menu)
            }
        }
    }

    private var picker: some View {
        Picker(selection: selection) {
            Text(daemonDefaultLabel).interFont(Constants.Typography.bodyS).tag(Self.defaultSelectionID)
            ForEach(models) { model in
                Text(model.name).interFont(Constants.Typography.bodyS).tag(model.id)
            }
        } label: {
            Text("Model").interFont(Constants.Typography.bodyS)
        }
        .accessibilityIdentifier("creation.modelPicker")
    }

    var selection: Binding<String> {
        Binding(
            get: { selectedModel?.id ?? Self.defaultSelectionID },
            set: { id in selectedModel = models.first { $0.id == id } }
        )
    }
}
