#if !DEBUG
@testable import Intent
import Testing

/// Selected explicitly by the wrapper's Release smoke command (#468).
/// Absent from Debug so a Debug test bundle cannot satisfy that command.
struct ReleaseConfigurationTests {
    @Test func lowerSeverityLogsDoNotEvaluateMessages() {
        var evaluations = 0
        func message() -> String {
            evaluations += 1
            return "Release configuration check"
        }

        let category = AppLog.Category("release-verification")
        category.debug(message())
        category.info(message())
        category.notice(message())
        category.warning(message())

        #expect(evaluations == 0)
    }

    @Test func productionTransportHasNoPlaintextEscapeHatch() {
        #expect(!WebSocketConnection.plaintextLoopbackOverrideActive)
        #expect(throws: WebSocketTransportError.self) {
            _ = try WebSocketConnection.makeURL(host: "127.0.0.1", port: 4242, certFingerprint: nil)
        }
    }

    @Test func demoLaunchFlagsAreIgnored() {
        let arguments = ["--demo-data", "--pretend-paired"]
        #expect(!DemoMode.demoDataRequested(by: arguments))
        #expect(!DemoMode.pretendPairedRequested(by: arguments))
        #expect(!DemoMode.isEnabled)
        #expect(!DemoMode.pretendPaired)
    }
}
#endif
