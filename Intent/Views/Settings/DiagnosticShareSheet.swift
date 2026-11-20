import SwiftUI
import UIKit

struct DiagnosticShareSheet: UIViewControllerRepresentable {
    let lease: DiagnosticShareLease
    let onFinished: @MainActor @Sendable (UUID, Bool, Bool) -> Void

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [lease.report.archiveURL], applicationActivities: nil)
        let lease = lease
        let onFinished = onFinished
        controller.completionWithItemsHandler = { @Sendable _, _, _, error in
            let failed = error != nil
            Task {
                let cleaned = await lease.finish()
                await onFinished(lease.id, failed, cleaned)
            }
        }
        return controller
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}
