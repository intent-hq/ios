import Foundation
import TailcatKit
import Testing
@testable import Intent

/// Smoke tests for the vendored TailcatKit.xcframework (gomobile bind
/// of TailcatKit/, wrapping github.com/tailscale/tailcat).
///
/// The byte-exchange test needs a running tailcat echo server to dial:
/// the CI harness starts TailcatKit/cmd/tcecho and passes its token via
/// the TAILCAT_SMOKE_TOKEN environment variable. Without the variable
/// that test is skipped, but the API-surface tests still run, verifying
/// the framework links and its Swift projection behaves.
struct TailcatKitSmokeTests {
    // nonisolated: the .enabled(if:) trait evaluates in a Sendable
    // closure, which cannot touch main-actor-isolated state under the
    // project's default MainActor isolation.
    nonisolated static var smokeToken: String? {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["TAILCAT_SMOKE_TOKEN"], !token.isEmpty else { return nil }
        return token
    }

    @Test func invalidPortIsRejected() throws {
        let client = try #require(TailcatkitNewClient("tc-not-a-real-token"))
        defer { try? client.close() }
        #expect(throws: (any Error).self) {
            try client.dial(0, timeoutMs: 1000)
        }
    }

    @Test func invalidForwardPortIsRejected() throws {
        let client = try #require(TailcatkitNewClient("tc-not-a-real-token"))
        defer { try? client.close() }
        #expect(throws: (any Error).self) {
            try client.forward(70000)
        }
    }

    @Test(.enabled(if: smokeToken != nil))
    func dialEchoAndExchangeBytes() throws {
        let token = try #require(Self.smokeToken)
        let client = try #require(TailcatkitNewClient(token))
        defer { try? client.close() }

        let conn = try client.dial(4711, timeoutMs: 60_000)
        defer { try? conn.close() }

        let message = Data("hello from iOS".utf8)
        try conn.write(message)
        try conn.setDeadlineMs(60_000)

        var received = Data()
        while received.count < message.count {
            // Read throws an error whose description is "EOF" at end of
            // stream (an empty Go slice would bridge to nil NSData and
            // break the throws -> Data projection, so EOF is out-of-band).
            do {
                received.append(try conn.read(message.count - received.count))
            } catch where error.localizedDescription == "EOF" {
                break
            }
        }
        #expect(received == message)
    }
}

/// Ordering logic of the dial-cancellation bridge. Uses an unused
/// gomobile client (close on it is a no-op), so no network is involved.
struct TailcatDialHandleTests {
    @Test func registerAfterCancelIsRefused() throws {
        let handle = TailcatTunnelDialer.DialHandle()
        let client = try #require(TailcatkitNewClient("tc-not-a-real-token"))
        defer { try? client.close() }

        #expect(!handle.isCancelled)
        handle.cancel()
        #expect(handle.isCancelled)
        #expect(!handle.register(client))
    }

    @Test func registerBeforeCancelIsAccepted() throws {
        let handle = TailcatTunnelDialer.DialHandle()
        let client = try #require(TailcatkitNewClient("tc-not-a-real-token"))
        defer { try? client.close() }

        #expect(handle.register(client))
        #expect(handle.cancelledAt == nil)
        handle.cancel()
        #expect(handle.isCancelled)
        #expect(handle.cancelledAt != nil)
    }

    @Test func cancelIsIdempotent() throws {
        let handle = TailcatTunnelDialer.DialHandle()
        let client = try #require(TailcatkitNewClient("tc-not-a-real-token"))
        defer { try? client.close() }

        #expect(handle.register(client))
        handle.cancel()
        let first = try #require(handle.cancelledAt)
        handle.cancel()
        #expect(handle.cancelledAt == first)
    }

    @Test func cancelDoesNotBlockCaller() throws {
        let handle = TailcatTunnelDialer.DialHandle()
        let client = try #require(TailcatkitNewClient("tc-not-a-real-token"))
        defer { try? client.close() }

        #expect(handle.register(client))
        let start = CFAbsoluteTimeGetCurrent()
        handle.cancel()
        // The close is dispatched off-thread; the cancel call itself must
        // return promptly even when the Go side would take its time.
        #expect(CFAbsoluteTimeGetCurrent() - start < 1)
    }
}
