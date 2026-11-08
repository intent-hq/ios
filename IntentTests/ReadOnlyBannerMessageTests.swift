import Foundation
@testable import Intent
import Network
import Testing

struct ReadOnlyBannerMessageTests {
    private func title(_ startup: DaemonStartupState?, network: NetworkAvailability.Status = .satisfied) -> String {
        ReadOnlyBannerMessage(networkStatus: network, machineName: "Studio", startupState: startup).title
    }

    private func status(
        _ phase: DaemonStartupStatus.Phase,
        progress: DaemonStartupStatus.Progress? = nil
    ) -> DaemonStartupStatus {
        DaemonStartupStatus(
            attemptID: "boot",
            phase: phase,
            progressAgeMs: 0,
            retryAfterMs: 1000,
            progress: progress,
            estimatedRemainingMs: nil,
            finalizingStep: phase == .finalizing ? .services : nil
        )
    }

    @Test func withoutStartupItNamesTheMac() {
        #expect(title(nil) == "Reconnecting to Studio… · Read-only")
        #expect(title(.unavailable) == "Reconnecting to Studio… · Read-only")
    }

    @Test func startupPhasesReplaceTheGenericReconnectingCopy() {
        #expect(title(.starting(nil)) == "Desktop is starting… · Read-only")
        #expect(title(.starting(status(.preparing))) == "Desktop is starting… · Read-only")
        #expect(title(.starting(status(.indexing))) == "Desktop is indexing notes… · Read-only")
        let progress = DaemonStartupStatus.Progress(completedNotes: 3, totalNotes: 10, processedSourceBytes: 1, totalSourceBytes: 2)
        #expect(title(.starting(status(.indexing, progress: progress))) == "Indexing notes (3 of 10)… · Read-only")
        #expect(title(.starting(status(.finalizing))) == "Desktop is finishing startup… · Read-only")
        #expect(title(.starting(status(.ready))) == "Connecting securely… · Read-only")
        #expect(title(.failed) == "Startup failed · Read-only")
    }

    @Test func aPhoneSideNetworkProblemStillWinsOverStartup() {
        #expect(title(.starting(nil), network: .unsatisfied(.notAvailable)) == "No network connection · Read-only")
    }
}
