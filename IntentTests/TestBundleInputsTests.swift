import Foundation
import Testing

struct TestBundleInputsTests {
    @Test func validInputsPreservePathsAndBytes() throws {
        try withFixture { root in
            let bytes = Data([0, 10, 255])
            let files = validFiles(overrides: ["Intent/App.swift": bytes])
            try writeFixture(files, to: root)

            let inputs = try TestBundleInputs(rootURL: root)
            #expect(inputs.relativePaths == files.keys.sorted())
            #expect(try Data(contentsOf: inputs.url(for: "Intent/App.swift")) == bytes)
            #expect(try inputs.swiftFiles(under: "Intent").map(\.path) == ["Intent/App.swift"])
            #expect(try inputs.swiftFiles(under: "IntentTests").map(\.path) == [
                "IntentTests/AppTests.swift"
            ])
        }
    }

    @Test func ancestorPathAliasesResolveWithoutWeakeningContainment() throws {
        try withFixture { root in
            try writeFixture(validFiles(), to: root)
            let parent = root.deletingLastPathComponent()
            let aliasParent = parent.appendingPathComponent("TestBundleInputsAlias-\(UUID().uuidString)")
            try FileManager.default.createSymbolicLink(at: aliasParent, withDestinationURL: parent)
            defer { try? FileManager.default.removeItem(at: aliasParent) }

            let aliasedRoot = aliasParent.appendingPathComponent(root.lastPathComponent)
            let realFile = root.appendingPathComponent("Intent/App.swift")
            #expect(try TestBundleInputs.relativePath(for: realFile, under: aliasedRoot) ==
                "Intent/App.swift")
            #expect(try TestBundleInputs(rootURL: aliasedRoot).relativePaths ==
                validFiles().keys.sorted())

            let outside = parent.appendingPathComponent("Outside-\(UUID().uuidString).swift")
            try write(Data("outside".utf8), to: outside)
            defer { try? FileManager.default.removeItem(at: outside) }
            #expect(throws: TestBundleInputsError.self) {
                try TestBundleInputs.relativePath(for: outside, under: aliasedRoot)
            }

            let rootAlias = parent.appendingPathComponent("RootAlias-\(UUID().uuidString)")
            try FileManager.default.createSymbolicLink(at: rootAlias, withDestinationURL: root)
            defer { try? FileManager.default.removeItem(at: rootAlias) }
            #expect(throws: TestBundleInputsError.self) {
                try TestBundleInputs(rootURL: rootAlias)
            }
        }
    }

    @Test func missingRootAndManifestFail() throws {
        try withFixture { root in
            try FileManager.default.removeItem(at: root)
            #expect(throws: TestBundleInputsError.self) {
                try TestBundleInputs(rootURL: root)
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            #expect(throws: TestBundleInputsError.self) {
                try TestBundleInputs(rootURL: root)
            }
        }
    }

    @Test func missingAndUnlistedFilesFail() throws {
        try withFixture { root in
            try writeFixture(validFiles(), to: root)
            try FileManager.default.removeItem(at: root.appendingPathComponent("Intent/App.swift"))
            #expect(throws: TestBundleInputsError.self) {
                try TestBundleInputs(rootURL: root)
            }

            try writeFixture(validFiles(), to: root)
            try write(Data("extra".utf8), to: root.appendingPathComponent("Intent/Extra.swift"))
            #expect(throws: TestBundleInputsError.self) {
                try TestBundleInputs(rootURL: root)
            }
        }
    }

    @Test func unsafeOrIncompleteMembershipFails() throws {
        try withFixture { root in
            var files = validFiles()
            files["../Outside.swift"] = Data("outside".utf8)
            try writeFixture(files, to: root, writeFiles: false)
            #expect(throws: TestBundleInputsError.self) {
                try TestBundleInputs(rootURL: root)
            }

            files = validFiles()
            files.removeValue(forKey: "IntentTests/AppTests.swift")
            try writeFixture(files, to: root)
            #expect(throws: TestBundleInputsError.self) {
                try TestBundleInputs(rootURL: root)
            }
        }
    }

    private func validFiles(overrides: [String: Data] = [:]) -> [String: Data] {
        var files = [
            "Info-visionOS.plist": Data("vision".utf8),
            "Intent/App.swift": Data("app".utf8),
            "Intent/Info.plist": Data("ios".utf8),
            "IntentTests/AppTests.swift": Data("tests".utf8)
        ]
        files.merge(overrides) { _, replacement in replacement }
        return files
    }

    private func writeFixture(
        _ files: [String: Data],
        to root: URL,
        writeFiles: Bool = true
    ) throws {
        if writeFiles {
            for (path, data) in files {
                try write(data, to: root.appendingPathComponent(path))
            }
        }
        let manifest = files.keys.sorted().joined(separator: "\n") + "\n"
        try write(Data(manifest.utf8), to: root.appendingPathComponent("manifest.txt"))
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    private func withFixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestBundleInputs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
