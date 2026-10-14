import SwiftUI

/// Shared by initial connection and the scene-covering reconnection surface.
/// Counts are exact; any daemon estimate applies only to indexing, not readiness.
struct DaemonStartupProgressView: View {
    let state: DaemonStartupState
    var onRetry: (() -> Void)?

    private enum Layout {
        static let spacing: CGFloat = 12
        static let maximumWidth: CGFloat = 420
        static let millisecondsPerSecond = 1000
    }

    var body: some View {
        VStack(spacing: Layout.spacing) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("daemon-startup.title")
            if case .starting(let snapshot) = state {
                if let snapshot { details(snapshot) } else {
                    ProgressView().accessibilityLabel("Waiting for startup status")
                }
            }
            if state == .unavailable {
                Text("Startup status unavailable. Reconnecting securely…")
                    .accessibilityIdentifier("daemon-startup.unavailable")
            }
            if state == .failed {
                Text("Daemon startup failed. Check daemon logs.")
                if let onRetry {
                    Button("Retry Connection", action: onRetry)
                        .buttonStyle(IntentContentButtonStyle())
                        .accessibilityIdentifier("daemon-startup.retry")
                }
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: Layout.maximumWidth)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("daemon-startup.progress")
    }

    private var title: LocalizedStringKey {
        switch state {
        case .failed: "Startup Failed"
        case .unavailable: "Connecting to Desktop"
        case .starting(let snapshot):
            switch snapshot?.phase {
            case .indexing: "Indexing Notes"
            case .finalizing: "Finishing Startup"
            case .ready: "Connecting Securely"
            case .failed: "Startup Failed"
            case .preparing, nil: "Starting Desktop"
            }
        }
    }

    @ViewBuilder private func details(_ snapshot: DaemonStartupStatus) -> some View {
        if snapshot.phase == .indexing, let progress = snapshot.progress {
            Text("\(progress.completedNotes) of \(progress.totalNotes) notes indexed")
                .accessibilityIdentifier("daemon-startup.counts")
            if progress.totalNotes > 0 {
                ProgressView(value: Double(progress.completedNotes), total: Double(progress.totalNotes))
                    .accessibilityLabel("Notes indexed")
            }
            if snapshot.progressAgeMs >= DaemonStartupStatus.unchangedThresholdMs {
                Text("Still indexing; completed-note count unchanged.")
                    .accessibilityIdentifier("daemon-startup.unchanged")
            } else if let estimate = snapshot.estimatedRemainingMs {
                let seconds = max(1, Int((Double(estimate) / Double(Layout.millisecondsPerSecond)).rounded(.up)))
                Text("About \(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 1))) remaining for indexing")
                    .accessibilityIdentifier("daemon-startup.estimate")
            }
        } else {
            ProgressView().accessibilityLabel("Starting desktop")
        }
        if snapshot.phase == .finalizing {
            switch snapshot.finalizingStep {
            case .anchors: Text("Updating note anchors…")
            case .committing: Text("Saving index changes…")
            case .services: Text("Starting services…")
            case nil: Text("Finishing startup…")
            }
        }
    }
}
