import SwiftUI

struct ToastEvidenceView: View {
    let sourceBackendID: BackendID

    var body: some View {
        let toast = ToastInfo(
            agentId: "demo-agent-implementor",
            workspaceId: "demo-workspace-1",
            agentName: "Dashboard Implementor",
            workspaceName: "Add usage analytics dashboard",
            sourceBackendID: sourceBackendID
        )
        Group {
            if ProcessInfo.processInfo.arguments.contains("--toast-before") {
                BeforeToastView(toast: toast, onTap: {}, onDismiss: {})
            } else {
                ToastView(toast: toast, onTap: {}, onDismiss: {})
            }
        }
        .accessibilityIdentifier("toast.evidence")
    }
}
