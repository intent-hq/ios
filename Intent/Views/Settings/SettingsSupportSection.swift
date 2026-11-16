import SwiftUI

struct SettingsSupportSection: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingDiagnosticLogs = false

    var body: some View {
        VStack(spacing: 0) {
            Button { showingDiagnosticLogs = true } label: {
                SettingsActionLabel(title: "Export logs", image: .downloadFile)
            }
            Divider()
            NavigationLink {
                AcknowledgementsView()
                    .environment(\.colorScheme, colorScheme)
                    .toolbarColorScheme(colorScheme, for: .navigationBar)
                    .toolbar(.visible, for: .navigationBar)
            } label: {
                SettingsActionLabel(title: "Acknowledgements", image: .file)
            }
        }
        .background(SettingsStyle.card(for: colorScheme), in: .rect(cornerRadius: SettingsStyle.cardRadius))
        .sheet(isPresented: $showingDiagnosticLogs) {
            DiagnosticExportView()
                .preferredColorScheme(colorScheme)
        }
    }
}
