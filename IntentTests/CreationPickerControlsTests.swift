import Foundation
@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
struct CreationPickerControlsTests {
    // Both production forms scroll; this canvas keeps every measured row mounted at accessibility sizes.
    private static let pickerHostHeight: CGFloat = 1200
    private static let pickerSettleTimeout: TimeInterval = 3
    private static let requiredStableFrameSamples = 3

    @Test func providerPickersKeepCallbacksIndependentAndUseHostPolicy() {
        let signedIn = ProviderInfo(id: "auggie", authenticated: .signedIn)
        let signedOut = ProviderInfo(id: "codex", authenticated: .signedOut)
        let unknown = ProviderInfo(id: "grok", authenticated: .unknown)
        let providers = [signedIn, signedOut, unknown]
        var firstSelection: ProviderInfo? = signedIn
        var secondSelection: ProviderInfo? = signedIn
        var firstCallbacks: [String] = []
        var secondCallbacks: [String] = []
        let firstPicker = ProviderPicker(
            providers: providers,
            selectedProvider: firstSelection
        ) { provider in
            firstCallbacks.append(provider.id)
            guard provider.isSelectable, provider.id != firstSelection?.id else { return }
            firstSelection = provider
        }
        let secondPicker = ProviderPicker(
            providers: providers,
            selectedProvider: secondSelection
        ) { provider in
            secondCallbacks.append(provider.id)
            guard provider.isSelectable else { return }
            secondSelection = provider
        }

        firstPicker.selection.wrappedValue = signedIn.id
        #expect(firstSelection == signedIn)
        #expect(firstCallbacks == [signedIn.id])
        #expect(secondSelection == signedIn)

        firstPicker.selection.wrappedValue = signedOut.id
        #expect(firstSelection == signedIn)
        #expect(firstCallbacks == [signedIn.id, signedOut.id])
        #expect(secondSelection == signedIn)
        #expect(secondCallbacks.isEmpty)

        firstPicker.selection.wrappedValue = unknown.id
        #expect(firstSelection == unknown)
        #expect(firstCallbacks == [signedIn.id, signedOut.id, unknown.id])
        #expect(secondSelection == signedIn)

        secondPicker.selection.wrappedValue = signedOut.id
        #expect(secondSelection == signedIn)
        #expect(secondCallbacks == [signedOut.id])
        #expect(firstSelection == unknown)
    }

    @Test func providerLabelsDistinguishOnlyKnownSignedOutOptions() {
        let signedOut = ProviderInfo(id: "codex", authenticated: .signedOut)
        let unknown = ProviderInfo(id: "grok", authenticated: .unknown)

        #expect(ProviderPicker.optionLabel(for: signedOut) == "Codex (not signed in)")
        #expect(ProviderPicker.optionLabel(for: unknown) == "Grok")
    }

    @Test func modelPickersKeepBindingsIndependentForDefaultAndExplicitChoices() {
        let firstModels = [ModelInfo(id: "first", name: "First", provider: "auggie")]
        let secondModels = [ModelInfo(id: "second", name: "Second", provider: "grok")]
        var firstSelection: ModelInfo?
        var secondSelection: ModelInfo?
        let firstPicker = ModelPicker(
            models: firstModels,
            selectedModel: Binding(
                get: { firstSelection },
                set: { firstSelection = $0 }
            ),
            daemonDefaultLabel: "Provider default"
        )
        let secondPicker = ModelPicker(
            models: secondModels,
            selectedModel: Binding(
                get: { secondSelection },
                set: { secondSelection = $0 }
            ),
            daemonDefaultLabel: "Provider default"
        )

        firstPicker.selection.wrappedValue = firstModels[0].id
        #expect(firstSelection == firstModels[0])
        #expect(secondSelection == nil)

        secondPicker.selection.wrappedValue = secondModels[0].id
        #expect(secondSelection == secondModels[0])
        #expect(firstSelection == firstModels[0])

        firstPicker.selection.wrappedValue = ModelPicker.defaultSelectionID
        #expect(firstSelection == nil)
        #expect(secondSelection == secondModels[0])
    }

    @Test(
        .enabled(
            Comment(
                rawValue:
                    "SwiftUI publishes its accessibility tree only when accessibility is enabled "
                    + "for the process (scripts/xcodebuild.sh enables it on the simulator; a "
                    + "physical-device unit-test run needs VoiceOver or an XCUITest session)"
            )
        ) {
            await SyntheticBadgeHost.publishesAccessibilityTree()
        }
    )
    func bothSurroundingLayoutsRenderReadablePickersAtDynamicTypeSizes() async throws {
        for layout in PickerHostLayout.allCases {
            let normal = try await render(layout: layout, dynamicTypeSize: .large)
            let accessibility = try await render(layout: layout, dynamicTypeSize: .accessibility3)
            for snapshot in [normal, accessibility] {
                #expect(snapshot.provider.label?.contains("Provider") == true)
                #expect(snapshot.provider.label?.contains(PickerLayoutHost.provider.displayName) == true)
                #expect(snapshot.provider.value == nil)
                #expect(snapshot.model.label?.contains("Model") == true)
                #expect(snapshot.model.label?.contains(layout.expectedModelValue) == true)
                #expect(snapshot.model.value == nil)
                #expect(snapshot.provider.hasFiniteNonemptyFrame)
                #expect(snapshot.model.hasFiniteNonemptyFrame)
                #expect(snapshot.provider.hasMinimumInteractiveSize)
                #expect(snapshot.model.hasMinimumInteractiveSize)
                #expect(snapshot.horizontallyContains(snapshot.provider.frame))
                #expect(snapshot.horizontallyContains(snapshot.model.frame))
                #expect(snapshot.hostFrame.intersects(snapshot.provider.frame))
                #expect(snapshot.hostFrame.intersects(snapshot.model.frame))
                #expect(snapshot.hasNoMeaningfulVerticalOverlap)
            }
        }
    }

    @Test func pickerGeometryContractRejectsMaterialOverlapAndInvalidFrames() {
        let boundary: CGFloat = 100
        let lowerFrame = CGRect(x: 0, y: boundary, width: 200, height: 44)

        #expect(PickerLayoutSnapshot.hasNoMeaningfulVerticalOverlap(
            upper: CGRect(x: 0, y: 0, width: 200, height: boundary.nextUp),
            lower: lowerFrame
        ))
        #expect(!PickerLayoutSnapshot.hasNoMeaningfulVerticalOverlap(
            upper: CGRect(x: 0, y: 0, width: 200, height: boundary + 8),
            lower: lowerFrame
        ))

        let readable = PickerElementSnapshot(
            label: nil,
            value: nil,
            frame: lowerFrame,
            visibleControlFrame: lowerFrame,
            traits: []
        )
        let labelInflated = PickerElementSnapshot(
            label: nil,
            value: nil,
            frame: CGRect(x: 0, y: 0, width: 200, height: boundary + 8),
            visibleControlFrame: CGRect(x: 0, y: 0, width: 200, height: boundary),
            traits: []
        )
        let undersized = PickerElementSnapshot(
            label: nil,
            value: nil,
            frame: CGRect(x: 0, y: 0, width: 200, height: 43),
            visibleControlFrame: CGRect(x: 0, y: 0, width: 200, height: 43),
            traits: []
        )
        let invalid = PickerElementSnapshot(
            label: nil,
            value: nil,
            frame: .zero,
            visibleControlFrame: .zero,
            traits: []
        )
        #expect(readable.hasMinimumInteractiveSize)
        #expect(!undersized.hasMinimumInteractiveSize)
        #expect(!invalid.hasFiniteNonemptyFrame)
        #expect(PickerLayoutSnapshot(
            hostFrame: CGRect(x: 0, y: 0, width: 200, height: 200),
            provider: labelInflated,
            model: readable
        ).hasNoMeaningfulVerticalOverlap)
    }

    @Test(
        .enabled(
            Comment(
                rawValue:
                    "SwiftUI publishes its accessibility tree only when accessibility is enabled "
                    + "for the process (scripts/xcodebuild.sh enables it on the simulator; a "
                    + "physical-device unit-test run needs VoiceOver or an XCUITest session)"
            )
        ) {
            await SyntheticBadgeHost.publishesAccessibilityTree()
        }
    )
    func addAgentLayoutDisablesProviderPickerDuringCreation() async throws {
        let snapshot = try await render(layout: .agent, dynamicTypeSize: .large, isCreating: true)
        #expect(snapshot.provider.traits.contains(.notEnabled))
    }

    private func render(
        layout: PickerHostLayout,
        dynamicTypeSize: DynamicTypeSize,
        isCreating: Bool = false
    ) async throws -> PickerLayoutSnapshot {
        let content = NavigationStack {
            PickerLayoutHost(layout: layout, isCreating: isCreating)
        }
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        return try await SyntheticBadgeHost.render(
            content,
            width: 430,
            height: Self.pickerHostHeight
        ) { hostView, window in
            let settled = try Self.settledPickerElements(in: hostView, window: window)
            return PickerLayoutSnapshot(
                hostFrame: window.bounds,
                provider: Self.snapshot(
                    settled.provider,
                    visibleControlFrame: settled.providerVisibleFrame,
                    in: window
                ),
                model: Self.snapshot(
                    settled.model,
                    visibleControlFrame: settled.modelVisibleFrame,
                    in: window
                )
            )
        }
    }

    private static func snapshot(
        _ element: NSObject,
        visibleControlFrame: CGRect,
        in window: UIWindow
    ) -> PickerElementSnapshot {
        PickerElementSnapshot(
            label: element.accessibilityLabel,
            value: element.accessibilityValue,
            frame: window.convert(element.accessibilityFrame, from: nil),
            visibleControlFrame: visibleControlFrame,
            traits: element.accessibilityTraits
        )
    }

    private static func settledPickerElements(
        in hostView: UIView,
        window: UIWindow
    ) throws -> SettledPickerElements {
        // SwiftUI can finish Dynamic Type reflow after the host appears.
        let deadline = Date(timeIntervalSinceNow: pickerSettleTimeout)
        var previousFrames: (provider: CGRect, model: CGRect)?
        var stableFrameSamples = 0

        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            window.layoutIfNeeded()
            hostView.layoutIfNeeded()

            let provider = try pickerElement(identifier: "creation.providerPicker", in: hostView)
            let model = try pickerElement(identifier: "creation.modelPicker", in: hostView)
            let providerFrame = try visibleControlFrame(of: provider, in: window)
            let modelFrame = try visibleControlFrame(of: model, in: window)
            let framesMatch = previousFrames?.provider == providerFrame
                && previousFrames?.model == modelFrame
            stableFrameSamples = framesMatch ? stableFrameSamples + 1 : 1
            if stableFrameSamples >= requiredStableFrameSamples {
                return SettledPickerElements(
                    provider: provider,
                    providerVisibleFrame: providerFrame,
                    model: model,
                    modelVisibleFrame: modelFrame
                )
            }
            previousFrames = (providerFrame, modelFrame)
        }

        throw PickerInspectionError.framesDidNotSettle
    }

    private static func visibleControlFrame(of element: NSObject, in window: UIWindow) throws -> CGRect {
        let view = try #require(
            element as? UIView,
            "Hosted picker accessibility element did not expose its on-screen control view"
        )
        return view.visibleFrame(in: window)
    }

    private static func pickerElement(identifier: String, in hostView: UIView) throws -> NSObject {
        let deadline = Date(timeIntervalSinceNow: 3)
        var element = accessibilityElements(under: hostView).first { element in
            SyntheticBadgeHost.accessibilityIdentifier(of: element) == identifier
        }
        while element == nil, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            hostView.layoutIfNeeded()
            element = accessibilityElements(under: hostView).first { element in
                SyntheticBadgeHost.accessibilityIdentifier(of: element) == identifier
            }
        }
        return try #require(element, "Hosted picker \(identifier) did not publish an accessibility element")
    }

    private static func accessibilityElements(under root: NSObject) -> [NSObject] {
        var visited: Set<ObjectIdentifier> = []
        func visit(_ object: NSObject, depth: Int) -> [NSObject] {
            guard depth < 12, visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            var children = (object.accessibilityElements ?? []).compactMap { $0 as? NSObject }
            let count = object.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                children += (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
            }
            if let view = object as? UIView { children += view.subviews }
            return [object] + children.flatMap { visit($0, depth: depth + 1) }
        }
        return visit(root, depth: 0)
    }
}

private enum PickerInspectionError: Error {
    case framesDidNotSettle
}

private struct SettledPickerElements {
    let provider: NSObject
    let providerVisibleFrame: CGRect
    let model: NSObject
    let modelVisibleFrame: CGRect
}

private enum PickerHostLayout: CaseIterable {
    case agent
    case workspace

    var expectedModelValue: String {
        switch self {
        case .workspace:
            SpecialistInfo.daemonDefaultLabel(
                for: PickerLayoutHost.specialist,
                providerId: PickerLayoutHost.provider.id
            )
        case .agent:
            PickerLayoutHost.model.name
        }
    }
}

private struct PickerElementSnapshot {
    // Apple's minimum tappable target is 44 points in each dimension.
    private static let minimumInteractiveDimension: CGFloat = 44

    let label: String?
    let value: String?
    let frame: CGRect
    let visibleControlFrame: CGRect
    let traits: UIAccessibilityTraits

    var hasFiniteNonemptyFrame: Bool {
        let values = [frame.minX, frame.minY, frame.width, frame.height]
        return values.allSatisfy { $0.isFinite } && frame.width > 0 && frame.height > 0
    }

    var hasMinimumInteractiveSize: Bool {
        frame.width >= Self.minimumInteractiveDimension
            && frame.height >= Self.minimumInteractiveDimension
    }
}

private struct PickerLayoutSnapshot {
    let hostFrame: CGRect
    let provider: PickerElementSnapshot
    let model: PickerElementSnapshot

    var hasNoMeaningfulVerticalOverlap: Bool {
        // SwiftUI may fold a row caption into the accessibility frame, while List clips a
        // menu button whose raw UIView bounds extend beyond its row. Compare what is visible.
        Self.hasNoMeaningfulVerticalOverlap(
            upper: provider.visibleControlFrame,
            lower: model.visibleControlFrame
        )
    }

    func horizontallyContains(_ frame: CGRect) -> Bool {
        frame.minX >= hostFrame.minX && frame.maxX <= hostFrame.maxX
    }

    static func hasNoMeaningfulVerticalOverlap(upper: CGRect, lower: CGRect) -> Bool {
        // Coordinate arithmetic can round a shared boundary by one representable value.
        let tolerance = max(upper.maxY.ulp, lower.minY.ulp)
        return upper.maxY <= lower.minY + tolerance
    }
}

private extension UIView {
    func visibleFrame(in window: UIWindow) -> CGRect {
        var frame = window.convert(bounds, from: self)
        var ancestor = superview
        while let view = ancestor {
            if view.clipsToBounds { frame = frame.intersection(window.convert(view.bounds, from: view)) }
            ancestor = view.superview
        }
        return frame
    }
}

private struct PickerLayoutHost: View {
    static let provider = ProviderInfo(
        id: "provider-with-an-extraordinarily-long-name",
        authenticated: .unknown
    )
    static let model = ModelInfo(
        id: "model-with-an-extraordinarily-long-id",
        name: "Model with an extraordinarily long descriptive name",
        provider: provider.id
    )
    static let specialist = SpecialistInfo(
        id: "implementor",
        name: "Implementor",
        description: "Implements tasks",
        resolvedModel: model.id,
        resolvedProvider: provider.id
    )

    let layout: PickerHostLayout
    let isCreating: Bool
    @State private var selectedSpecialist: SpecialistInfo? = Self.specialist
    @State private var selectedProvider: ProviderInfo? = Self.provider
    @State private var selectedModel: ModelInfo?
    @State private var message = ""
    @State private var showError = false

    init(layout: PickerHostLayout, isCreating: Bool) {
        self.layout = layout
        self.isCreating = isCreating
        _selectedModel = State(initialValue: layout == .agent ? Self.model : nil)
    }

    @ViewBuilder
    var body: some View {
        switch layout {
        case .workspace:
            CreateWorkspaceSpecialistStepView(
                repositoryFullName: "intent-hq/repository-with-a-long-name",
                branch: "feature/long-picker-accessibility-values",
                specialists: [Self.specialist],
                isLoadingSpecialists: false,
                selectedSpecialist: $selectedSpecialist,
                providers: [Self.provider],
                isLoadingProviders: false,
                selectedProvider: $selectedProvider,
                models: [Self.model],
                selectedModel: $selectedModel,
                messageText: $message,
                isCreating: isCreating,
                errorMessage: nil,
                showError: $showError,
                colorScheme: .light,
                onSelectProvider: selectWorkspaceProvider,
                onCreate: {},
                onLoad: {}
            )
        case .agent:
            ProviderModelStepView(
                providers: [Self.provider],
                isLoadingProviders: false,
                selectedProvider: $selectedProvider,
                models: [Self.model],
                isLoadingModels: false,
                selectedModel: $selectedModel,
                selectedSpecialist: Self.specialist,
                isCreating: isCreating,
                isCreateDisabled: isCreating,
                colorScheme: .light,
            ) {}
        }
    }

    private func selectWorkspaceProvider(_ provider: ProviderInfo) {
        guard provider.isSelectable, provider.id != selectedProvider?.id else { return }
        selectedProvider = provider
        selectedModel = nil
    }
}
