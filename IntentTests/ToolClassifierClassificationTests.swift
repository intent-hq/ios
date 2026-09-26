@testable import Intent
import Testing

struct ToolClassifierClassificationTests {
    private struct TitleFixture {
        let title: String
        let verb: String
        let subject: String
    }

    @Test func terminalTitleVerbsPreserveTheirDisplaySemantics() {
        let fixtures = [
            TitleFixture(title: "Run `swift test`", verb: "Run", subject: "swift test"),
            TitleFixture(title: "Launch `pnpm dev`", verb: "Launch", subject: "pnpm dev"),
            TitleFixture(title: "Read terminal 5", verb: "Read", subject: "terminal 5"),
            TitleFixture(title: "List processes", verb: "List", subject: "processes"),
            TitleFixture(title: "Kill terminal 5", verb: "Kill", subject: "terminal 5"),
            TitleFixture(title: "Write terminal 5", verb: "Write to", subject: "terminal 5")
        ]

        for fixture in fixtures {
            let display = ToolClassifier.classify(name: "launch-process", input: [
                "_acpTitle": AnyCodable(fixture.title)
            ])
            #expect(display.icon == .terminal)
            #expect(display.verb == fixture.verb)
            #expect(display.subject == fixture.subject)
        }
    }

    @Test func explicitCommandTakesPrecedenceOverTitleFallback() {
        let display = ToolClassifier.classify(name: "launch-process", input: [
            "command": AnyCodable("swift test\nignored second line"),
            "_acpTitle": AnyCodable("Kill terminal 5")
        ])

        #expect(display.icon == .terminal)
        #expect(display.verb == "Run")
        #expect(display.subject == "swift test")
    }

    @Test func terminalOperationNameTakesPrecedenceOverCommandAndTitle() {
        let display = ToolClassifier.classify(name: "read-process", input: [
            "command": AnyCodable("swift test"),
            "_acpTitle": AnyCodable("Kill terminal 5")
        ])

        #expect(display.icon == .terminal)
        #expect(display.verb == "Read")
        #expect(display.subject == "terminal")
    }

    @Test func commandInputPreservesTerminalPrecedenceForOtherwiseUnknownTool() {
        let display = ToolClassifier.classify(name: "unrecognized-tool", input: [
            "command": AnyCodable("echo hello"),
            "_acpTitle": AnyCodable("Summarize recent activity for the user")
        ])

        #expect(display.icon == .terminal)
        #expect(display.verb == "Run")
        #expect(display.subject == "echo hello")
    }

    @Test func malformedTerminalTitleFallsBackToGenericRunDisplay() {
        let display = ToolClassifier.classify(name: "launch-process", input: [
            "_acpTitle": AnyCodable("Inspect repository")
        ])

        #expect(display.icon == .terminal)
        #expect(display.verb == "Run")
        #expect(display.subject == nil)
    }
}
