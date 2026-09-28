import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceScriptDiscoveryTests {
    @Test func intentappPackageExposesAllTenScriptsUsingPnpm() throws {
        let entries = [
            "dev": "astro dev", "build": "astro build", "preview": "astro preview", "astro": "astro",
            "lint": "eslint .", "format": "prettier --write .", "format:check": "prettier --check .",
            "test": "vitest run", "test:specwriter": "vitest run specwriter", "test:specwriter:browser": "playwright test"
        ]
        let scripts = try packageScripts(entries, manager: "pnpm@10.17.1")
        #expect(scripts.map(\.name) == entries.keys.sorted())
        #expect(scripts.allSatisfy { $0.command == "pnpm run \($0.name)" })
        #expect(scripts.allSatisfy { $0.id == "manifest:package.json:\($0.name)" })
        #expect(scripts.allSatisfy { !$0.isRegistered && !$0.hasRun && $0.status == "idle" && $0.workspaceId == "workspace" })
        #expect(scripts.allSatisfy { $0.detectedURL == nil && $0.error == nil })
        #expect(scripts.filter { $0.mode == "service" }.map(\.name) == ["dev", "preview"])
    }

    @Test func missingMalformedAndNonObjectScriptsAreIgnored() {
        let inputs = ["", "not json", "null", "[]", "{}", #"{"scripts":[]}"#, #"{"scripts":"dev"}"#, #"{"scripts":null}"#]
        for input in inputs {
            #expect(discover(["package.json": input]).isEmpty)
        }
        #expect(discover([:]).isEmpty)
        #expect(discover(["Cargo.toml": "# empty", "pyproject.toml": "[project]", "Makefile": "not a target"]).isEmpty)
        #expect(discover(["nested/package.json": #"{"scripts":{"dev":"vite"}}"#]).isEmpty)
    }

    @Test func invalidCommandsAndEmptyOrOptionLikeNamesAreRejected() throws {
        let entries: [String: Any] = [
            "": "vite", "   ": "vite", "--help": "vite", "-dev": "vite", " --version": "vite",
            "new\nline": "vite", "tab\tname": "vite", "nul\0name": "vite",
            "empty": "", "whitespace": " \n\t", "number": 1, "boolean": true, "null": NSNull(),
            "array": ["vite"], "object": ["command": "vite"], "nul-command": "echo\0bad", "dev": "vite"
        ]
        let scripts = try packageScripts(entries)
        #expect(scripts.map(\.name) == ["dev"])
        #expect(scripts.first?.command == "npm run dev")
    }

    @Test func declaredPackageManagerWinsOverConflictingLockfiles() throws {
        let lockfiles: Set<String> = ["pnpm-lock.yaml", "yarn.lock", "bun.lock", "package-lock.json"]
        for manager in ["pnpm", "yarn", "npm", "bun"] {
            let scripts = try packageScripts(["dev": "vite"], manager: "\(manager)@1.0.0", fileNames: lockfiles)
            #expect(scripts.first?.command == "\(manager) run dev")
        }
        let unversioned = try packageScripts(["dev": "vite"], manager: "bun", fileNames: ["pnpm-lock.yaml"])
        #expect(unversioned.first?.command == "bun run dev")
    }

    @Test func lockfileSelectionIsDeterministicAndDefaultsToNpm() throws {
        let cases: [(Set<String>, String)] = [
            (["pnpm-lock.yaml", "yarn.lock", "bun.lock"], "pnpm"),
            (["yarn.lock", "bun.lockb"], "yarn"),
            (["bun.lock"], "bun"), (["bun.lockb"], "bun"),
            (["package-lock.json"], "npm"), (["npm-shrinkwrap.json"], "npm"), ([], "npm")
        ]
        for (files, manager) in cases {
            let scripts = try packageScripts(["dev": "vite"], fileNames: files)
            #expect(scripts.first?.command == "\(manager) run dev")
        }
    }

    @Test func unsupportedOrInvalidManagerFallsBackToLockfiles() throws {
        for manager in ["", "deno@2", "pnpm@", "npm run", "bun@1.0; echo bad", "pnpm\nrun"] {
            let scripts = try packageScripts(["dev": "vite"], manager: manager, fileNames: ["yarn.lock"])
            #expect(scripts.first?.command == "yarn run dev")
        }
        let content = #"{"packageManager":false,"scripts":{"dev":"vite"}}"#
        let scripts = WorkspaceScriptDiscovery.scripts(workspaceId: "workspace", files: ["package.json": content], fileNames: ["pnpm-lock.yaml"])
        #expect(scripts.first?.command == "pnpm run dev")
    }

    @Test func unsafeNamesAreSingleArgumentsInsteadOfShellSyntax() throws {
        let cases = [
            "dev preview": "npm run 'dev preview'",
            "it's preview": #"npm run 'it'"'"'s preview'"#,
            "$(touch injected)": "npm run '$(touch injected)'",
            "`touch injected`": "npm run '`touch injected`'",
            "; touch injected": "npm run '; touch injected'",
            "dev|cat": "npm run 'dev|cat'",
            "dev*": "npm run 'dev*'",
            "dev ": "npm run 'dev '",
            "test:unit": "npm run test:unit"
        ]
        let scripts = try packageScripts(cases.mapValues { _ in "echo example" })
        #expect(scripts.count == cases.count)
        for script in scripts { #expect(script.command == cases[script.name]) }
    }

    @Test func makefileFindsDistinctTargetsAndIgnoresRecipesAndDirectives() {
        let content = [
            ".PHONY: dev build", "dev build:", "\techo dev", "test:: dependency", "build: dependency",
            "%.o: %.c", ".hidden:", "  indented:", "VARIABLE := value", "VARIABLE = value",
            "no-space:dependency", "check:", "release.v2:", "# comment: ignored"
        ].joined(separator: "\r\n")
        let scripts = discover(["Makefile": content])
        #expect(scripts.map(\.name) == ["dev", "build", "test", "check", "release.v2"])
        #expect(scripts.allSatisfy { $0.command == "make \($0.name)" })
        #expect(scripts.first?.mode == "service")
        #expect(scripts.allSatisfy { !$0.isRegistered && !$0.hasRun })
    }

    @Test func cargoRecognizesPackageWorkspaceAndBinaryManifests() {
        for header in ["[package]", "[workspace]", "[[bin]]"] {
            let scripts = discover(["Cargo.toml": "# Rust project\n\(header)\nname = \"example\""])
            #expect(scripts.map(\.name) == ["build", "test", "check"])
            #expect(scripts.map(\.command) == ["cargo build", "cargo test", "cargo check"])
            #expect(scripts.allSatisfy { $0.mode == "command" })
        }
        #expect(discover(["Cargo.toml": "[dependencies]\n# [package]\n[package.metadata]"]).isEmpty)
    }

    @Test func pythonPrefersBlackAndMypyWhenAlternativeToolsArePresent() {
        let content = "[tool.pytest.ini_options]\n[tool.ruff]\n[tool.black]\n[tool.mypy]\n[tool.pyright]"
        let scripts = discover(["pyproject.toml": content])
        #expect(scripts.map(\.name) == ["test", "lint", "format", "typecheck"])
        #expect(scripts.map(\.command) == ["pytest", "ruff check .", "black .", "mypy ."])
        #expect(scripts.allSatisfy { $0.mode == "command" })
    }

    @Test func pythonFindsRuffSubtablesAndPyrightWithToolSpecificFallbacks() {
        let scripts = discover(["pyproject.toml": "[tool.pytest]\n[tool.ruff.lint]\n[tool.pyright]"])
        #expect(scripts.map(\.command) == ["pytest", "ruff check .", "ruff format .", "pyright"])
        #expect(discover(["pyproject.toml": "[tool.black]"]).map(\.command) == ["black ."])
        #expect(discover(["pyproject.toml": "# [tool.pytest]\n[tool.unrecognized]"]).isEmpty)
    }

    @Test func duplicateNamesUseDesktopPrefixesAndNumericSuffixes() {
        let files = [
            "package.json": """
            {"scripts":{"test":"vitest","make:test":"echo existing","make:test-2":"echo existing",
            "cargo:test":"echo existing","python:test":"echo existing","dev":"vite"}}
            """,
            "Makefile": "test:\ndev:", "Cargo.toml": "[package]", "pyproject.toml": "[tool.pytest]"
        ]
        let scripts = discover(files)
        let byID = Dictionary(uniqueKeysWithValues: scripts.map { ($0.id, $0) })
        #expect(byID["manifest:Makefile:test"]?.name == "make:test-3")
        #expect(byID["manifest:Makefile:dev"]?.name == "make:dev")
        #expect(byID["manifest:Makefile:dev"]?.mode == "service")
        #expect(byID["manifest:Makefile:test"]?.command == "make test")
        #expect(byID["manifest:Cargo.toml:test"]?.name == "cargo:test-2")
        #expect(byID["manifest:pyproject.toml:test"]?.name == "python:test-2")
        #expect(Set(scripts.map(\.name)).count == scripts.count)
        #expect(Set(scripts.map(\.id)).count == scripts.count)
        #expect(discover(files) == scripts)
        let withoutCollision = discover(["Makefile": "test:"]).first
        #expect(withoutCollision?.id == byID["manifest:Makefile:test"]?.id)
    }

    @Test func serviceClassificationMatchesDesktopPrecedence() throws {
        let services = [
            "dev", "DEV", "start", "serve", "develop", "storybook", "watch", "preview", "dev:web", "dev-server",
            "start:app", "start-dev", "storybook:docs", "watch:test", "watch-build", "some-storybook-thing"
        ]
        let commands = [
            "build", "test", "lint", "typecheck", "type-check", "format", "fmt", "prettier", "eslint", "check",
            "test:storybook", "build-storybook", "lint:storybook", "format-storybook", "typecheck:storybook",
            "type-check:storybook", "unknown", "serve:api", "preview:app", "watchdog"
        ]
        let entries = Dictionary(uniqueKeysWithValues: (services + commands).map { ($0, "echo example") })
        let scripts = try packageScripts(entries)
        #expect(Set(scripts.filter { $0.mode == "service" }.map(\.name)) == Set(services))
        #expect(Set(scripts.filter { $0.mode == "command" }.map(\.name)) == Set(commands))
    }

    @Test func registrationMetadataPreservesExistingRuntimeEvidence() throws {
        let existing = WorkspaceScript(id: "saved", workspaceId: "workspace", name: "Saved", command: "echo done")
        #expect(existing.mode == "command")
        #expect(existing.isRegistered)
        #expect(!existing.hasRun)
        let row: [String: Any] = [
            "id": "saved", "workspaceId": "workspace", "name": "Saved", "command": "npm run dev", "mode": "service",
            "runtime": ["status": "idle", "previouslyRunning": true]
        ]
        let restored = try #require(WorkspaceScript(definition: row, workspaceId: "workspace"))
        #expect(restored.mode == "service")
        #expect(restored.isRegistered)
        #expect(restored.hasRun)
        var noMode = row
        noMode.removeValue(forKey: "mode")
        #expect(WorkspaceScript(definition: noMode, workspaceId: "workspace")?.mode == "command")
        let other = WorkspaceScriptDiscovery.scripts(workspaceId: "other", files: ["Cargo.toml": "[package]"], fileNames: [])
        #expect(other.allSatisfy { $0.workspaceId == "other" && !$0.isRegistered && !$0.hasRun })
    }

    private func discover(_ files: [String: String]) -> [WorkspaceScript] {
        WorkspaceScriptDiscovery.scripts(workspaceId: "workspace", files: files, fileNames: Set(files.keys))
    }

    private func packageScripts(_ scripts: [String: Any], manager: String? = nil, fileNames: Set<String> = []) throws -> [WorkspaceScript] {
        var object: [String: Any] = ["scripts": scripts]
        if let manager { object["packageManager"] = manager }
        let data = try JSONSerialization.data(withJSONObject: object)
        let content = try #require(String(data: data, encoding: .utf8))
        return WorkspaceScriptDiscovery.scripts(workspaceId: "workspace", files: ["package.json": content], fileNames: fileNames)
    }
}
