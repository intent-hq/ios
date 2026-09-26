import SwiftUI

enum HomeActionDestination: String, Identifiable {
    case acknowledgements
    case appearance

    var id: String { rawValue }
}

struct HomeActionSettingsView: View {
    let destination: HomeActionDestination
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appThemePreference") private var themePreference = "system"
    @State private var showingLogs = false

    var body: some View {
        NavigationStack {
            Form {
                if destination == .appearance {
                    Picker("Appearance", selection: $themePreference) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.inline)
                } else {
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }
                    Button("Export logs") { showingLogs = true }
                }
            }
            .navigationTitle(destination == .appearance ? "Appearance" : "Acks & Logs")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingLogs) { DiagnosticExportView() }
        }
    }
}
