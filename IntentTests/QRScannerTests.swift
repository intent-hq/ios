import Foundation
@testable import Intent
import Testing

@MainActor
struct QRScannerTests {
    private static let validCode = "intent://pair?host=192.168.1.10&port=5181&token=secret-token&fp=aa:bb:cc"

    @Test func invalidCodeEntersAutoClearingErrorAndClearMatchesOnlyCurrentToken() throws {
        var state = QRScannerSessionState()
        let decision = state.receiveScannedCode("not-a-pairing-uri")

        #expect(decision == .invalidInput)
        #expect(!state.isValidating)
        #expect(state.errorMessage == QRScannerSessionState.invalidCodeMessage)
        let autoClearID = try #require(state.errorAutoClearID)

        // Stale timer token from an earlier scan must not clear the current error.
        state.clearError(matching: UUID())
        #expect(state.errorMessage != nil)

        state.clearError(matching: autoClearID)
        #expect(state.errorMessage == nil)
        #expect(state.phase == .idle)
    }

    @Test func validScanBlocksDuplicateScansAndTransitionsThroughFingerprintConfirmation() throws {
        var state = QRScannerSessionState()
        guard case let .validate(payload) = state.receiveScannedCode(Self.validCode) else {
            Issue.record("Expected valid pairing payload")
            return
        }
        #expect(state.isValidating)
        #expect(state.errorMessage == nil)
        let whileValidating = state.receiveScannedCode(Self.validCode)
        #expect(whileValidating == .ignoreWhileBusy)

        state.requestFingerprintConfirmation(payload: payload, fingerprint: "11:22:33")
        #expect(state.isConfirmingFingerprint)
        #expect(state.isValidating)
        #expect(state.probedFingerprint == "11:22:33")
        let whileConfirming = state.receiveScannedCode(Self.validCode)
        #expect(whileConfirming == .ignoreWhileBusy)

        let rawConfirmed = state.consumeConfirmedFingerprint()
        let confirmed = try #require(rawConfirmed)
        #expect(confirmed.payload == payload)
        #expect(confirmed.fingerprint == "11:22:33")
        #expect(!state.isConfirmingFingerprint)
        #expect(state.isValidating)

        state.fail("Connection failed: refused")
        #expect(!state.isValidating)
        #expect(state.errorAutoClearID == nil, "Probe/connect failures stay visible until a new scan")
        #expect(state.errorMessage == "Connection failed: refused")
    }

    @Test func cancellingFingerprintConfirmationReturnsToIdle() {
        var state = QRScannerSessionState()
        guard case let .validate(payload) = state.receiveScannedCode(Self.validCode) else {
            Issue.record("Expected valid pairing payload")
            return
        }
        state.requestFingerprintConfirmation(payload: payload, fingerprint: "11:22:33")
        state.cancelConfirmation()

        #expect(state.phase == .idle)
        #expect(!state.isValidating)
        #expect(!state.isConfirmingFingerprint)
    }

    @Test func deduplicatorSuppressesRepeatedBarcodesUntilExpiredOrChanged() {
        var deduplicator = QRScannerDeduplicator()
        let emptyAccept = deduplicator.accept([])
        #expect(emptyAccept == nil)
        let firstAccept = deduplicator.accept(["code-1", "code-2"])
        #expect(firstAccept == "code-1")
        let duplicateAccept = deduplicator.accept(["code-1"])
        #expect(duplicateAccept == nil, "Immediate repeat of the same barcode is ignored")

        // A different barcode is accepted immediately and supersedes the earlier expiry timer.
        let changedAccept = deduplicator.accept(["code-2"])
        #expect(changedAccept == "code-2")
        let staleExpire = deduplicator.expire(matching: "code-1")
        #expect(!staleExpire, "Timer for superseded code-1 must no-op")
        let repeatSecond = deduplicator.accept(["code-2"])
        #expect(repeatSecond == nil)

        let validExpire = deduplicator.expire(matching: "code-2")
        #expect(validExpire)
        let rescanAfterCooldown = deduplicator.accept(["code-2"])
        #expect(rescanAfterCooldown == "code-2", "Same barcode can re-scan after cooldown")
    }
}
