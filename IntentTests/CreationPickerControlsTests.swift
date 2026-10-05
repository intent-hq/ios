import Foundation
@testable import Intent
import SwiftUI
import Testing
import UIKit

// Hosted picker inspection and its geometry fixtures intentionally live together.
// swiftlint:disable file_length type_body_length

@MainActor
@Suite(.serialized)
struct CreationPickerControlsTests {
    // Both production forms scroll; this canvas keeps every measured row mounted at accessibility sizes.
    private static let pickerHostHeight: CGFloat = 2400
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
                #expect(snapshot.provider.spokenDescription.contains(PickerLayoutHost.provider.displayName))
                #expect(snapshot.model.label?.contains("Model") == true)
                #expect(snapshot.model.spokenDescription.contains(layout.expectedModelValue))
                #expect(snapshot.provider.hasFiniteNonemptyAccessibilityFrame)
                #expect(snapshot.model.hasFiniteNonemptyAccessibilityFrame)
                #expect(snapshot.provider.hasMinimumAccessibilityFrameSize)
                #expect(snapshot.model.hasMinimumAccessibilityFrameSize)
                #expect(snapshot.horizontallyContains(snapshot.provider.frame))
                #expect(snapshot.horizontallyContains(snapshot.model.frame))
                #expect(snapshot.hostFrame.intersects(snapshot.provider.frame))
                #expect(snapshot.hostFrame.intersects(snapshot.model.frame))
                #expect(snapshot.provider.hasFiniteNonemptyVisibleControlFrame)
                #expect(snapshot.model.hasFiniteNonemptyVisibleControlFrame)
                #expect(snapshot.provider.hasReadableVisibleControlSize)
                #expect(snapshot.model.hasReadableVisibleControlSize)
                #expect(snapshot.hostFrame.contains(snapshot.provider.visibleControlFrame))
                #expect(snapshot.hostFrame.contains(snapshot.model.visibleControlFrame))
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
        let accessibilityUndersized = PickerElementSnapshot(
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
        #expect(readable.hasMinimumAccessibilityFrameSize)
        #expect(readable.hasReadableVisibleControlSize)
        #expect(!accessibilityUndersized.hasMinimumAccessibilityFrameSize)
        #expect(accessibilityUndersized.hasReadableVisibleControlSize)
        #expect(!invalid.hasFiniteNonemptyAccessibilityFrame)
        #expect(!invalid.hasFiniteNonemptyVisibleControlFrame)
        #expect(PickerLayoutSnapshot(
            hostFrame: CGRect(x: 0, y: 0, width: 200, height: 200),
            provider: labelInflated,
            model: readable
        ).hasNoMeaningfulVerticalOverlap)
    }

    // Exercises the actual capture/association path, with healthy non-UIView AX metadata.
    // CGRect-only fixtures cannot detect a broken pixel sensor or coordinate conversion.
    @Test(arguments: [
        "valid", "providerClipped", "modelClipped", "narrow", "short", "overlap",
        "outside", "missing", "unrelated", "ambiguous"
    ])
    func renderedPickerObservationRejectsBrokenGeometry(fault: String) async throws {
        let fixture = UIView()
        fixture.backgroundColor = UIColor(CreateWorkspaceFormStyle.background(for: .light))
        try await SyntheticBadgeHost.render(PickerOracleView(view: fixture), width: 240, height: 240) { _, window in
            try #require(fixture.bounds.size == window.bounds.size)
            try Self.inspectRenderedFault(fault, host: fixture, window: window)
        }
    }

    // swiftlint:disable:next function_body_length
    private static func inspectRenderedFault(_ fault: String, host: UIView, window: UIWindow) throws {
        let providerRect = CGRect(x: 40, y: 20, width: 120, height: 60)
        let modelRect = providerRect.offsetBy(dx: 0, dy: 100)
        let provider = Self.paintedControl(frame: providerRect, in: host)
        let model = Self.paintedControl(frame: modelRect, in: host)
        Self.applyRenderedFault(fault, provider: provider, model: model, host: host)
        let rendered = try Self.settledRenderedFixture(in: window)
        // Capture can finish safe-area reflow. Convert only after the painted fixture has
        // settled, keeping local, window-pixel and screen-space AX coordinates separate.
        let expectedFrames = [providerRect, modelRect].map { window.convert($0, from: host) }
        let metadata = expectedFrames.enumerated().map { index, frame in
            let element = UIAccessibilityElement(accessibilityContainer: host)
            element.accessibilityIdentifier = index == 0 ? "creation.providerPicker" : "creation.modelPicker"
            element.accessibilityLabel = index == 0 ? "Provider" : "Model"
            element.accessibilityValue = "Valid selected value"
            element.accessibilityTraits = .button
            element.accessibilityFrame = window.convert(frame, to: nil)
            return element
        }
        host.accessibilityElements = metadata
        window.layoutIfNeeded()
        let elements = try ["creation.providerPicker", "creation.modelPicker"].map { identifier in
            try Self.pickerElement(identifier: identifier, in: host)
        }
        let axFrames = elements.map { window.convert($0.accessibilityFrame, from: nil) }
        #expect(axFrames == expectedFrames)
        for element in elements {
            let snapshot = Self.snapshot(element, visibleControlFrame: .zero, in: window)
            #expect(snapshot.hasFiniteNonemptyAccessibilityFrame)
            #expect(snapshot.hasMinimumAccessibilityFrameSize)
            #expect(snapshot.spokenDescription.contains("Valid selected value"))
        }
        try rendered.record(named: "picker-oracle-\(fault)")
        switch fault {
        case "overlap":
            #expect(throws: CreationPickerRenderedGeometry.ObservationError.sharedRegion) {
                try rendered.frames(associatedWith: axFrames)
            }
        case "outside":
            #expect(throws: CreationPickerRenderedGeometry.ObservationError.clippedAtCaptureEdge) {
                try rendered.frames(associatedWith: axFrames)
            }
        case "missing", "unrelated", "ambiguous", "providerClipped", "modelClipped":
            // The one-point clipped strip is resampled with its background;
            // no complete card-color region remains, despite valid, unchanged AX bounds.
            #expect(throws: CreationPickerRenderedGeometry.ObservationError.missingOrAmbiguousRegion) {
                try rendered.frames(associatedWith: axFrames)
            }
        default:
            let measured = try rendered.frames(associatedWith: axFrames)
            let snapshot = PickerLayoutSnapshot(
                hostFrame: window.bounds,
                provider: Self.snapshot(elements[0], visibleControlFrame: measured[0], in: window),
                model: Self.snapshot(elements[1], visibleControlFrame: measured[1], in: window)
            )
            #expect(snapshot.hasValidVisibleControlGeometry == (fault == "valid"))
            if fault == "valid" {
                for (actual, expected) in zip(measured, expectedFrames) {
                    // A 1px interior edge can be blended by drawHierarchy's 1x capture.
                    // Assert each edge, not just size, so flipping/offsetting the image fails.
                    #expect(abs(actual.minX - expected.minX) <= 1)
                    #expect(abs(actual.minY - expected.minY) <= 1)
                    #expect(abs(actual.maxX - expected.maxX) <= 1)
                    #expect(abs(actual.maxY - expected.maxY) <= 1)
                }
            }
        }
    }

    private static func settledRenderedFixture(in window: UIWindow) throws -> CreationPickerRenderedGeometry {
        let deadline = Date(timeIntervalSinceNow: pickerSettleTimeout)
        var previous: [CGRect] = []
        var stableSamples = 0
        var samples: [String] = []
        // Slow image capture must still allow enough observations to establish stability.
        while Date() < deadline || samples.count < requiredStableFrameSamples {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            window.layoutIfNeeded()
            let rendered = try CreationPickerRenderedGeometry(window: window)
            samples.append("Sample \(samples.count + 1): regions=\(rendered.regions)")
            stableSamples = previous == rendered.regions ? stableSamples + 1 : 1
            if stableSamples >= requiredStableFrameSamples { return rendered }
            previous = rendered.regions
        }
        throw PickerInspectionError.framesDidNotSettle(samples: Array(samples.suffix(requiredStableFrameSamples)))
    }

    private static func paintedControl(frame: CGRect, in host: UIView) -> UIButton {
        let control = UIButton(frame: frame)
        control.backgroundColor = UIColor(CreateWorkspaceFormStyle.card(for: .light))
        control.isAccessibilityElement = false
        host.addSubview(control)
        return control
    }

    private static func applyRenderedFault(_ fault: String, provider: UIView, model: UIView, host: UIView) {
        switch fault {
        case "providerClipped", "modelClipped":
            let control = fault == "providerClipped" ? provider : model
            let clipper = UIView(frame: CGRect(x: control.frame.minX, y: control.frame.midY, width: 120, height: 1))
            clipper.clipsToBounds = true
            host.addSubview(clipper)
            clipper.addSubview(control)
            control.frame = CGRect(x: 0, y: -30, width: 120, height: 60)
        case "narrow": provider.frame = CGRect(x: 90, y: 20, width: 20, height: 60)
        case "short": provider.frame = CGRect(x: 40, y: 40, width: 120, height: 20)
        case "overlap": provider.frame.size.height = 108
        case "outside": provider.frame = CGRect(x: -10, y: 20, width: 170, height: 60)
        case "missing": provider.isHidden = true
        case "unrelated": provider.frame.origin.x = 180
        case "ambiguous":
            let ring = UIView(frame: provider.frame.insetBy(dx: -10, dy: -10))
            ring.layer.borderWidth = 4
            ring.layer.borderColor = provider.backgroundColor?.cgColor
            host.addSubview(ring)
        default: break
        }
    }

    // swiftlint:disable:next function_body_length
    @Test func pickerGeometryContractRejectsInvalidClippedVisibleFrames() {
        let hostFrame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let validAccessibilityFrame = CGRect(x: 40, y: 20, width: 120, height: 60)
        let lowerAccessibilityFrame = validAccessibilityFrame.offsetBy(dx: 0, dy: 100)
        let upper = Self.geometrySnapshot(
            accessibilityFrame: validAccessibilityFrame,
            visibleControlFrame: CGRect(x: 40, y: 20, width: 120, height: 44)
        )
        let lower = Self.geometrySnapshot(
            accessibilityFrame: lowerAccessibilityFrame,
            visibleControlFrame: CGRect(x: 40, y: 120, width: 120, height: 44)
        )
        let providerStrip = Self.geometrySnapshot(
            accessibilityFrame: validAccessibilityFrame,
            visibleControlFrame: CGRect(x: 40, y: 20, width: 120, height: 1)
        )
        let modelStrip = Self.geometrySnapshot(
            accessibilityFrame: lowerAccessibilityFrame,
            visibleControlFrame: CGRect(x: 40, y: 120, width: 120, height: 1)
        )
        #expect(providerStrip.hasFiniteNonemptyAccessibilityFrame)
        #expect(providerStrip.hasMinimumAccessibilityFrameSize)
        #expect(providerStrip.hasFiniteNonemptyVisibleControlFrame)
        #expect(!providerStrip.hasReadableVisibleControlSize)
        #expect(modelStrip.hasFiniteNonemptyAccessibilityFrame)
        #expect(modelStrip.hasMinimumAccessibilityFrameSize)
        #expect(modelStrip.hasFiniteNonemptyVisibleControlFrame)
        #expect(!modelStrip.hasReadableVisibleControlSize)
        #expect(!PickerLayoutSnapshot(
            hostFrame: hostFrame,
            provider: providerStrip,
            model: lower
        ).hasValidVisibleControlGeometry)
        #expect(!PickerLayoutSnapshot(
            hostFrame: hostFrame,
            provider: upper,
            model: modelStrip
        ).hasValidVisibleControlGeometry)

        let invalidVisible = Self.geometrySnapshot(
            accessibilityFrame: validAccessibilityFrame,
            visibleControlFrame: .null
        )
        let outsideHost = Self.geometrySnapshot(
            accessibilityFrame: validAccessibilityFrame,
            visibleControlFrame: CGRect(x: -1, y: 20, width: 120, height: 44)
        )
        #expect(!PickerLayoutSnapshot(
            hostFrame: hostFrame,
            provider: invalidVisible,
            model: lower
        ).hasValidVisibleControlGeometry)
        #expect(!PickerLayoutSnapshot(
            hostFrame: hostFrame,
            provider: outsideHost,
            model: lower
        ).hasValidVisibleControlGeometry)
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
        .environment(\.colorScheme, .light)
        return try await SyntheticBadgeHost.render(
            content,
            width: 430,
            height: layout == .workspace ? Self.pickerHostHeight : 1200,
            diagnostics: SyntheticBadgeHostTrace(context: "picker layout=\(layout) dynamicType=\(dynamicTypeSize) isCreating=\(isCreating)")
        ) { hostView, window in
            let settled = try Self.settledPickerElements(in: hostView, window: window, layout: layout)
            try CreationPickerRenderedGeometry(window: window).record(named: "\(layout)-\(dynamicTypeSize)")
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

    private static func geometrySnapshot(
        accessibilityFrame: CGRect,
        visibleControlFrame: CGRect
    ) -> PickerElementSnapshot {
        PickerElementSnapshot(
            label: nil,
            value: nil,
            frame: accessibilityFrame,
            visibleControlFrame: visibleControlFrame,
            traits: []
        )
    }

    private static func settledPickerElements(
        in hostView: UIView,
        window: UIWindow,
        layout: PickerHostLayout
    ) throws -> SettledPickerElements {
        // SwiftUI can finish Dynamic Type reflow after the host appears.
        let deadline = Date(timeIntervalSinceNow: pickerSettleTimeout)
        var previousFrames: (provider: CGRect, model: CGRect)?
        var stableFrameSamples = 0
        var samples: [String] = []

        // Slow image capture must still allow enough observations to establish stability.
        while Date() < deadline || samples.count < requiredStableFrameSamples {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            window.layoutIfNeeded()
            hostView.layoutIfNeeded()

            let provider = try pickerElement(identifier: "creation.providerPicker", in: hostView)
            let model = try pickerElement(identifier: "creation.modelPicker", in: hostView)
            let frames: [CGRect]
            if layout == .workspace {
                let rendered = try CreationPickerRenderedGeometry(window: window)
                do {
                    frames = try rendered.frames(associatedWith: [provider, model].map { element in
                        window.convert(element.accessibilityFrame, from: nil)
                    })
                } catch {
                    try rendered.record(named: "picker-observation-failure")
                    throw error
                }
            } else {
                frames = try [provider, model].map { try visibleMenuRowFrame(of: $0, under: hostView, in: window) }
            }
            let providerFrame = frames[0]
            let modelFrame = frames[1]
            samples.append("Sample \(samples.count + 1): provider=\(providerFrame), model=\(modelFrame)")
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

        throw PickerInspectionError.framesDidNotSettle(samples: Array(samples.suffix(requiredStableFrameSamples)))
    }

    private static func visibleMenuRowFrame(of element: NSObject, under root: UIView, in window: UIWindow) throws -> CGRect {
        let accessibilityFrame = window.convert(element.accessibilityFrame, from: nil)
        let center = CGPoint(x: accessibilityFrame.midX, y: accessibilityFrame.midY)
        func matchingCells(under view: UIView) -> [UICollectionViewCell] {
            if let cell = view as? UICollectionViewCell,
               cell.window === window, !cell.isHidden,
               window.convert(cell.bounds, from: cell).contains(center) {
                return [cell]
            }
            return view.subviews.flatMap { matchingCells(under: $0) }
        }
        let cells = matchingCells(under: root)
        try #require(cells.count == 1, "Each picker must occupy a distinct rendered list row")
        let view = try #require(cells.first).contentView
        var frame = window.convert(view.bounds, from: view)
        var ancestor = view.superview
        while let parent = ancestor {
            if parent.clipsToBounds { frame = frame.intersection(window.convert(parent.bounds, from: parent)) }
            ancestor = parent.superview
        }
        return frame
    }

    private static func pickerElement(identifier: String, in hostView: UIView) throws -> NSObject {
        let deadline = Date(timeIntervalSinceNow: 3)
        var elements = accessibilityElements(under: hostView).filter { element in
            SyntheticBadgeHost.accessibilityIdentifier(of: element) == identifier
        }
        while elements.isEmpty, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            hostView.layoutIfNeeded()
            elements = accessibilityElements(under: hostView).filter { element in
                SyntheticBadgeHost.accessibilityIdentifier(of: element) == identifier
            }
        }
        try #require(elements.count == 1, "Hosted picker \(identifier) must publish exactly one element")
        return try #require(elements.first)
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

private struct PickerOracleView: UIViewRepresentable {
    let view: UIView

    func makeUIView(context _: Context) -> UIView { view }
    func updateUIView(_: UIView, context _: Context) {}
}

private enum PickerInspectionError: Error {
    case framesDidNotSettle(samples: [String])
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
    private static let minimumAccessibilityFrameDimension: CGFloat = 44
    // The hosted menu chrome renders about 34 points high. This floor detects clipping without
    // claiming that the measured visible rectangle is the control's complete hit target.
    private static let minimumReadableVisibleControlDimension: CGFloat = 32

    let label: String?
    let value: String?
    let frame: CGRect
    let visibleControlFrame: CGRect
    let traits: UIAccessibilityTraits

    var spokenDescription: String {
        [label, value].compactMap { $0 }.joined(separator: ", ")
    }

    var hasFiniteNonemptyAccessibilityFrame: Bool {
        let values = [frame.minX, frame.minY, frame.width, frame.height]
        return values.allSatisfy { $0.isFinite } && frame.width > 0 && frame.height > 0
    }

    var hasMinimumAccessibilityFrameSize: Bool {
        frame.width >= Self.minimumAccessibilityFrameDimension
            && frame.height >= Self.minimumAccessibilityFrameDimension
    }

    var hasFiniteNonemptyVisibleControlFrame: Bool {
        let values = [
            visibleControlFrame.minX,
            visibleControlFrame.minY,
            visibleControlFrame.width,
            visibleControlFrame.height
        ]
        return values.allSatisfy { $0.isFinite }
            && visibleControlFrame.width > 0
            && visibleControlFrame.height > 0
    }

    var hasReadableVisibleControlSize: Bool {
        visibleControlFrame.width >= Self.minimumReadableVisibleControlDimension
            && visibleControlFrame.height >= Self.minimumReadableVisibleControlDimension
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

    var hasValidVisibleControlGeometry: Bool {
        [provider, model].allSatisfy { element in
            element.hasFiniteNonemptyVisibleControlFrame
                && element.hasReadableVisibleControlSize
                && hostFrame.contains(element.visibleControlFrame)
        } && hasNoMeaningfulVerticalOverlap
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
    @State private var images = WorkspaceCreationImages()
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
                providerGuidance: nil,
                selectedProvider: selectedProvider,
                models: [Self.model],
                selectedModel: $selectedModel,
                reasoningLevels: [],
                selectedReasoningEffort: .constant(nil),
                messageText: $message,
                images: images,
                isCreating: isCreating,
                allowsCreation: true,
                errorMessage: nil,
                showError: $showError,
                colorScheme: .light,
                onSelectProvider: selectWorkspaceProvider,
                onRetryProviders: {},
                onBack: {},
                onCreate: {},
                onLoad: {}
            )
        case .agent:
            ProviderModelStepView(
                providers: [Self.provider],
                isLoadingProviders: false,
                providerGuidance: nil,
                selectedProvider: $selectedProvider,
                models: [Self.model],
                isLoadingModels: false,
                selectedModel: $selectedModel,
                selectedSpecialist: Self.specialist,
                isCreating: isCreating,
                isCreateDisabled: isCreating,
                colorScheme: .light,
                onRetryProviders: {},
                onCreate: {}
            )
        }
    }

    private func selectWorkspaceProvider(_ provider: ProviderInfo) {
        guard provider.isSelectable, provider.id != selectedProvider?.id else { return }
        selectedProvider = provider
        selectedModel = nil
    }
}
// swiftlint:enable file_length type_body_length
