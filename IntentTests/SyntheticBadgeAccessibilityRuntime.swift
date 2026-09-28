import Darwin
import Foundation

/// Unit-test runners do not start XCTest's UI automation session. Simulator
/// preferences alone do not activate SwiftUI's in-process accessibility tree.
/// This test-bundle-only switch uses the same runtime entry points as
/// CashApp AccessibilitySnapshot's ASAccessibilityEnabler; never link into Intent.
@MainActor final class SyntheticBadgeAccessibilityRuntime {
    struct Interface {
        let read: @MainActor () -> Int32
        let write: @MainActor (Int32) -> Void
        let close: @MainActor () -> Void
    }

    enum RuntimeError: Error, Equatable {
        case libraryUnavailable
        case symbolsUnavailable
        case activationFailed
    }

    static let shared = SyntheticBadgeAccessibilityRuntime(load: loadAutomation)
    private let load: @MainActor () throws -> Interface
    private var interface: Interface?
    private var original: Int32 = 0
    private var owners: Set<UUID> = []

    init(load: @escaping @MainActor () throws -> Interface) { self.load = load }

    func acquire() throws -> UUID {
        if interface == nil {
            let loaded = try load()
            let previous = loaded.read()
            loaded.write(1)
            guard loaded.read() != 0 else {
                loaded.write(previous)
                loaded.close()
                throw RuntimeError.activationFailed
            }
            interface = loaded
            original = previous
            print("SYNTHETIC accessibility automation: before=\(previous) enabled=\(loaded.read())")
        }
        let owner = UUID()
        owners.insert(owner)
        return owner
    }

    func release(_ owner: UUID) {
        guard owners.remove(owner) != nil, owners.isEmpty, let interface else { return }
        self.interface = nil
        interface.write(original)
        print("SYNTHETIC accessibility automation: restored=\(interface.read()) expected=\(original)")
        interface.close()
    }

    private static func loadAutomation() throws -> Interface {
        let library = "/usr/lib/libAccessibility.dylib"
        let path = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent(library).path } ?? library
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { throw RuntimeError.libraryUnavailable }
        guard let getter = dlsym(handle, "_AXSAutomationEnabled"),
              let setter = dlsym(handle, "_AXSSetAutomationEnabled") else {
            dlclose(handle)
            throw RuntimeError.symbolsUnavailable
        }
        let read = unsafeBitCast(getter, to: (@convention(c) () -> Int32).self)
        let write = unsafeBitCast(setter, to: (@convention(c) (Int32) -> Void).self)
        return Interface(read: { read() }, write: { write($0) }, close: { dlclose(handle) })
    }
}
