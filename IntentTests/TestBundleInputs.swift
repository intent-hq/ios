import Foundation

enum TestBundleInputsError: Error, CustomStringConvertible {
    case contentsMismatch(missing: [String], extra: [String])
    case invalidManifest(String)
    case invalidRoot(String)
    case missingInput(String)
    case unsafePath(String)

    var description: String {
        switch self {
        case let .invalidRoot(message), let .invalidManifest(message):
            message
        case let .unsafePath(path):
            "unsafe test input path: \(path)"
        case let .contentsMismatch(missing, extra):
            "test inputs differ from manifest; missing: \(missing), extra: \(extra)"
        case let .missingInput(path):
            "test input is missing from manifest: \(path)"
        }
    }
}

private final class TestBundleInputsToken: NSObject {}

struct TestBundleInputs {
    private static let manifestName = "manifest.txt"

    let rootURL: URL
    let relativePaths: [String]

    static func current(bundle: Bundle? = nil) throws -> Self {
        let resolvedBundle = bundle ?? Bundle(for: TestBundleInputsToken.self)
        guard let resourceURL = resolvedBundle.resourceURL else {
            throw TestBundleInputsError.invalidRoot("test bundle has no resource URL")
        }
        return try Self(rootURL: resourceURL.appendingPathComponent("SourceInputs"))
    }

    init(rootURL: URL) throws {
        let standardizedRoot = rootURL.standardizedFileURL
        try Self.requireRealDirectory(standardizedRoot)
        self.rootURL = standardizedRoot.resolvingSymlinksInPath()

        let manifestURL = self.rootURL.appendingPathComponent(Self.manifestName)
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw TestBundleInputsError.invalidManifest("missing test input manifest at \(manifestURL.path)")
        }
        guard let manifest = String(data: data, encoding: .utf8) else {
            throw TestBundleInputsError.invalidManifest("test input manifest is not UTF-8")
        }
        let paths = manifest.split(separator: "\n").map(String.init)
        guard !paths.isEmpty,
              paths.joined(separator: "\n") + "\n" == manifest,
              paths == paths.sorted(),
              Set(paths).count == paths.count
        else {
            throw TestBundleInputsError.invalidManifest(
                "test input manifest must be nonempty, sorted, unique, and newline-terminated"
            )
        }
        for path in paths where !Self.isAllowed(path) {
            throw TestBundleInputsError.unsafePath(path)
        }
        guard paths.contains("Intent/Info.plist"), paths.contains("Info-visionOS.plist"),
              paths.contains(where: { $0.hasPrefix("Intent/") && $0.hasSuffix(".swift") }),
              paths.contains(where: { $0.hasPrefix("IntentTests/") && $0.hasSuffix(".swift") })
        else {
            throw TestBundleInputsError.invalidManifest(
                "test input manifest is missing a required plist or Swift source root"
            )
        }

        let actualPaths = try Self.actualFiles(under: self.rootURL)
        let missing = Set(paths).subtracting(actualPaths).sorted()
        let extra = actualPaths.subtracting(paths).sorted()
        guard missing.isEmpty, extra.isEmpty else {
            throw TestBundleInputsError.contentsMismatch(missing: missing, extra: extra)
        }
        relativePaths = paths
    }

    func url(for relativePath: String) throws -> URL {
        guard relativePaths.contains(relativePath) else {
            throw TestBundleInputsError.missingInput(relativePath)
        }
        return rootURL.appendingPathComponent(relativePath)
    }

    func swiftFiles(under directory: String) throws -> [(path: String, url: URL)] {
        guard directory == "Intent" || directory == "IntentTests" else {
            throw TestBundleInputsError.unsafePath(directory)
        }
        let prefix = directory + "/"
        return relativePaths.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".swift") }
            .map { ($0, rootURL.appendingPathComponent($0)) }
    }

    private static func isAllowed(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return false }
        if path == "Intent/Info.plist" || path == "Info-visionOS.plist" { return true }
        return path.hasSuffix(".swift")
            && (path.hasPrefix("Intent/") || path.hasPrefix("IntentTests/"))
    }

    private static func requireRealDirectory(_ url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            throw TestBundleInputsError.invalidRoot(
                "test input root is missing, not a directory, or a symlink: \(url.path)"
            )
        }
    }

    private static func actualFiles(under root: URL) throws -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        else {
            throw TestBundleInputsError.invalidRoot("cannot enumerate test inputs at \(root.path)")
        }
        var paths: Set<String> = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw TestBundleInputsError.unsafePath(url.path)
            }
            guard values.isRegularFile == true else { continue }
            let path = try relativePath(for: url, under: root)
            if path != manifestName { paths.insert(path) }
        }
        return paths
    }

    static func relativePath(for fileURL: URL, under rootURL: URL) throws -> String {
        let rootComponents = rootURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let fileComponents = fileURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard fileComponents.count > rootComponents.count,
              fileComponents.starts(with: rootComponents)
        else {
            throw TestBundleInputsError.unsafePath(fileURL.path)
        }
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }
}
