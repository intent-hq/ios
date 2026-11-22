import Foundation
@testable import Intent
import Testing

struct PairingOptionTests {
    @Test func excludesQRScanWithoutCameraScanning() {
        let options = PairingOption.available(
            showsSavedConnections: false,
            supportsCameraScanning: false
        )
        #expect(!options.contains(.qrScan))
        #expect(options == [.manualEntry])
    }

    @Test func offersQRScanFirstWithCameraScanning() {
        let options = PairingOption.available(
            showsSavedConnections: false,
            supportsCameraScanning: true
        )
        #expect(options == [.qrScan, .manualEntry])
    }

    @Test func appendsSavedConnectionsWhenRequested() {
        #expect(
            PairingOption.available(showsSavedConnections: true, supportsCameraScanning: true)
                == [.qrScan, .manualEntry, .savedConnections]
        )
        #expect(
            PairingOption.available(showsSavedConnections: true, supportsCameraScanning: false)
                == [.manualEntry, .savedConnections]
        )
    }

    @Test func platformDefaultMatchesBuildTarget() {
        #if os(visionOS)
        #expect(!PairingOption.platformSupportsCameraScanning)
        #expect(!PairingOption.available(showsSavedConnections: false).contains(.qrScan))
        #else
        #expect(PairingOption.platformSupportsCameraScanning)
        #expect(PairingOption.available(showsSavedConnections: false).contains(.qrScan))
        #endif
    }

    @Test func connectTextUsesApprovedTypography() throws {
        let source = try pairingSource()
        let mappings = [
            (#"Text("Connect to Intent")"#, "heading2"),
            (#"Text("Pair with your desktop app to manage workspaces and chat with agents.")"#, "bodyS"),
            ("Text(title)", "bodySEmphasized"),
            ("Text(subtitle)", "bodyS")
        ]
        for (text, style) in mappings {
            #expect(source.contains("\(text) .interFont(Constants.Typography.\(style))"))
        }
        #expect(source.components(separatedBy: ".interFont(Constants.Typography.").count - 1 == mappings.count + 1)
    }

    @Test func connectKeepsVisionHintCaptionRole() throws {
        let source = try pairingSource()
        let hint = "Pair from your iPhone or Mac: open the intent://pair link shown in the Intent desktop app."
        #expect(source.contains("Text(\"\(hint)\") .interFont(Constants.Typography.subtextXXS)"))
    }

    private func pairingSource() throws -> String {
        let url = try TestSourceInputs.url(for: "Intent/Views/Onboarding/PairingView.swift")
        return try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
