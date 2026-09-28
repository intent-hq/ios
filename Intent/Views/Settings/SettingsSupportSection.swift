import SwiftUI

struct SettingsSupportSection: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingDiagnosticLogs = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink {
                AcknowledgementsView()
                    .toolbar(.visible, for: .navigationBar)
            } label: {
                SettingsActionLabel(title: "Acknowledgements", image: .file)
            }
            Divider()
            Button { showingDiagnosticLogs = true } label: {
                SettingsActionLabel(title: "Export logs", image: .downloadFile)
            }
        }
        .background(SettingsStyle.card(for: colorScheme), in: .rect(cornerRadius: SettingsStyle.cardRadius))
        .sheet(isPresented: $showingDiagnosticLogs) { DiagnosticExportView() }
    }
}
