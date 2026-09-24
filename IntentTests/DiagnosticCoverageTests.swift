import Foundation
@testable import Intent
import Testing

struct DiagnosticCoverageTests {
    @Test func registerAccountsForEveryOperationFamilyWithoutClaimingProducersExist() throws {
        #expect(Set(DiagnosticCoverage.entries.map(\.family)) == Set(DiagnosticFamily.allCases))
        #expect(Set(DiagnosticOperation.allCases.map(\.family)) == Set(DiagnosticFamily.allCases))
        #expect(DiagnosticCoverage.entries.allSatisfy { $0.status == .pending })
        for entry in DiagnosticCoverage.entries {
            _ = try TestSourceInputs.url(for: "Intent/\(entry.source)")
            _ = try TestSourceInputs.url(for: "IntentTests/\(entry.test)")
        }
    }

    @Test func recordAPIHasNoFreeFormPayloadOrConditionalCompilation() throws {
        let source = try String(contentsOf: TestSourceInputs.url(for: "Intent/Utils/DiagnosticStore.swift"), encoding: .utf8)
        #expect(source.contains("func record(_ event: DiagnosticEvent, scope: Scope? = nil) -> Bool"))
        #expect(!source.contains("#if DEBUG"))
        let schema = try String(contentsOf: TestSourceInputs.url(for: "Intent/Utils/DiagnosticEvent.swift"), encoding: .utf8)
        for forbidden in [": String\n", ": Error", ": NSError", "[String:", "#file", "#function"] {
            #expect(!schema.contains(forbidden))
        }
        let appLog = try String(contentsOf: TestSourceInputs.url(for: "Intent/Utils/AppLog.swift"), encoding: .utf8)
        #expect(!appLog.contains("DiagnosticStore"))
        #expect(appLog.contains("privacy: .private"))
    }

    @Test func fileProtectionPolicyIsExplicitEvenWhenSimulatorCannotExposeAttributes() throws {
        let source = try String(contentsOf: TestSourceInputs.url(for: "Intent/Utils/DiagnosticFileStorage.swift"), encoding: .utf8)
        let directoryPolicy = "[.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]"
        #expect(source.components(separatedBy: directoryPolicy).count == 3)
        #expect(source.contains("options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]"))
        #expect(!source.contains("#if"))
    }
}
