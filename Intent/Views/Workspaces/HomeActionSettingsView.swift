import SwiftUI

struct HomeActionSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showingLogs = false

    var body: some View {
        NavigationStack {
            Form {
                NavigationLink("Acknowledgements") { AcknowledgementsView() }
                Button("Export logs") { showingLogs = true }
            }
            .navigationTitle("Acks & Logs")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingLogs) { DiagnosticExportView() }
        }
    }
}
