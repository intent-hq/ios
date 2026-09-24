import SwiftUI
import UIKit

struct DiagnosticShareSheet: UIViewControllerRepresentable {
    let lease: DiagnosticShareLease
    let onFinished: @MainActor @Sendable (UUID, Bool, Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [lease.report.archiveURL], applicationActivities: nil)
        let lease = lease
        let onFinished = onFinished
        // UIKit retains this callback (and the lease) for the consumer's
        // lifetime, even if SwiftUI removes the presenting view. No foreign
        // error, returned item, activity identifier, or URL goes into logs.
        controller.completionWithItemsHandler = { @Sendable _, _, _, error in
            let failed = error != nil
            Task {
                let cleaned = await lease.finish()
                await onFinished(lease.id, failed, cleaned)
            }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}