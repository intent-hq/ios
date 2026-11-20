import Foundation
@testable import Intent
import SwiftUI
import Testing
import UIKit

struct ConnectionFailureViewTests {
    @Test @MainActor func accessibilityTextKeepsFailureContentScrollable() async throws {
        let fixtures = try BackendSessionRegistryTests()
        let session = fixtures.makeRegistry().makePairingSession()
        let view = ConnectionFailureView(
            errorMessage: "Your saved connection and settings were kept so you can retry disconnecting.",
            retryPolicy: .manualLogOff
        )
        .environment(session)
        .environment(session.makeCoordinator())
        .environment(\.dynamicTypeSize, .accessibility5)
        try await SyntheticBadgeHost.render(view, width: 320, height: 568) { host, _ in
            let scroll = try #require(Self.scrollView(in: host))
            #expect(scroll.contentSize.height > scroll.bounds.height)
            #expect(scroll.contentSize.width <= scroll.bounds.width)
            scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
            #expect(scroll.contentOffset.y > 0)
        }
    }

    @MainActor private static func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    @Test func aggregateRaceErrorRoutesToCertPath() {
        let error = WebSocketTransportError.certificateMismatches(mismatches: [
            HostCertMismatch(host: "h1", fingerprint: "aa:bb"),
            HostCertMismatch(host: "h2", fingerprint: "cc:dd")
        ])
        #expect(ConnectionFailureView.isCertificateMismatchMessage(error.localizedDescription))
    }

    @Test func singleMismatchErrorRoutesToCertPath() {
        let error = WebSocketTransportError.certificateMismatch(
            host: "h1",
            fingerprint: "aa:bb"
        )
        #expect(ConnectionFailureView.isCertificateMismatchMessage(error.localizedDescription))
    }

    @Test func repairPromptRoutesToCertPath() {
        #expect(ConnectionFailureView.isCertificateMismatchMessage(
            "Server certificate has changed. Please re-pair your device."
        ))
    }

    @Test func missingPinRefusalRoutesToCertPath() {
        let error = WebSocketTransportError.missingCertificatePin(host: "10.0.0.1")
        #expect(ConnectionFailureView.isCertificateMismatchMessage(error.localizedDescription))
    }

    @Test func genericFailuresDoNotRouteToCertPath() {
        #expect(!ConnectionFailureView.isCertificateMismatchMessage(
            "Connection to 192.168.1.42 timed out"
        ))
        #expect(!ConnectionFailureView.isCertificateMismatchMessage(
            "The server at 192.168.1.42:5179 is not responding."
        ))
    }

    @Test func shouldAutoRetryOnlyForOrdinaryAutomaticFailures() {
        #expect(ConnectionFailureView.shouldAutoRetry(
            retryPolicy: .automaticConnection,
            isCertMismatch: false
        ))
        #expect(!ConnectionFailureView.shouldAutoRetry(
            retryPolicy: .automaticConnection,
            isCertMismatch: true
        ))
        #expect(!ConnectionFailureView.shouldAutoRetry(
            retryPolicy: .manualLogOff,
            isCertMismatch: false
        ))
        #expect(!ConnectionFailureView.shouldAutoRetry(
            retryPolicy: .manualLogOff,
            isCertMismatch: true
        ))
    }

    @Test func retryBackoffIsExponentialAndCapped() {
        #expect(ConnectionFailureView.retryBackoff(attempt: 1) == .seconds(2))
        #expect(ConnectionFailureView.retryBackoff(attempt: 2) == .seconds(4))
        #expect(ConnectionFailureView.retryBackoff(attempt: 4) == .seconds(16))
        #expect(ConnectionFailureView.retryBackoff(attempt: 5) == .seconds(30))
        #expect(ConnectionFailureView.retryBackoff(attempt: 10) == .seconds(30))
    }

    private static func makeConnection(port: Int) -> StoredConnection {
        StoredConnection(
            server: PairedServer(
                hosts: ["10.0.0.1"],
                port: port,
                name: "daemon-\(port)",
                pairedAt: Date()
            ),
            token: "tok-\(port)"
        )
    }

    @Test func autoRetryDialsWindowBoundRecordNotAnotherSaved() {
        let lastUsed = Self.makeConnection(port: 1)
        let bound = Self.makeConnection(port: 2)

        let result = ConnectionFailureView.autoRetryConnection(
            connections: [lastUsed, bound],
            windowConnectionID: bound.id
        )

        #expect(result?.id == bound.id)
    }

    @Test func autoRetryHasNoTargetWhenBoundRecordDeleted() {
        let survivor = Self.makeConnection(port: 1)

        let result = ConnectionFailureView.autoRetryConnection(
            connections: [survivor],
            windowConnectionID: UUID()
        )

        #expect(result == nil)
    }

    @Test func autoRetryHasNoTargetInUnboundWindow() {
        let saved = Self.makeConnection(port: 1)

        #expect(ConnectionFailureView.autoRetryConnection(
            connections: [saved],
            windowConnectionID: nil
        ) == nil)
    }
}
