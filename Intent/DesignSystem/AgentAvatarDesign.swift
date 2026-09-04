import SwiftUI

/// The desktop agent avatar design catalog, ported from cloudlands-fe
/// `avatar-design.ts`. Builtin designs map to specialists; fallback designs
/// are picked deterministically from the agent id.
enum AgentAvatarDesign: String, CaseIterable {
    case coordinator
    case implementor
    case verifier
    case prReviewer = "pr-reviewer"
    case uiDesigner = "ui-designer"
    case chiefOfStaff = "chief-of-staff"
    case ralph
    case fallbackGlasses = "fallback-glasses"
    case fallbackCrown = "fallback-crown"
    case fallbackCrownInverted = "fallback-crown-inverted"
    case fallbackCrownMouth = "fallback-crown-mouth"
    case fallbackCode = "fallback-code"
    case fallbackDots = "fallback-dots"

    static let fallbackDesigns: [AgentAvatarDesign] = [
        .fallbackGlasses, .fallbackCrown, .fallbackCrownInverted,
        .fallbackCrownMouth, .fallbackCode, .fallbackDots,
    ]

    /// The named built-in designs a specialist `icon` may reference —
    /// everything except the seeded fallbacks (mirrors
    /// `builtinAgentAvatarDesigns` in avatar-design.ts).
    static let builtinDesigns: [AgentAvatarDesign] =
        allCases.filter { !fallbackDesigns.contains($0) }

    /// Whether a specialist `icon` value names one of the built-in designs
    /// (mirrors `isBuiltinAgentAvatarDesign` in avatar-design.ts).
    static func isBuiltinDesign(_ value: String) -> Bool {
        guard let design = AgentAvatarDesign(rawValue: value) else { return false }
        return builtinDesigns.contains(design)
    }

    /// Mirrors `builtinSpecialistAvatarDesigns` in avatar-design.ts.
    static let builtinSpecialistDesigns: [String: AgentAvatarDesign] = [
        "coordinator": .coordinator,
        "spec-writer": .coordinator,
        "implementor": .implementor,
        "verifier": .verifier,
        "developer": .verifier,
        "pr-reviewer": .prReviewer,
        "ui-designer": .uiDesigner,
        "chief-of-staff": .chiefOfStaff,
        "ralph": .ralph,
    ]

    /// Resolve the avatar design for an agent. Precedence: a valid specialist
    /// `icon` (PROTOCOL §5.11) → the hard-coded specialist-id map → the
    /// seeded fallback (mirrors `getAgentAvatarDesign` in avatar-design.ts).
    /// Unknown/absent icons degrade to the pre-icon behavior.
    static func design(agentId: String, specialist: String?, icon: String? = nil) -> AgentAvatarDesign {
        if let icon, isBuiltinDesign(icon), let design = AgentAvatarDesign(rawValue: icon) {
            return design
        }
        if let specialist, let builtin = builtinSpecialistDesigns[specialist] {
            return builtin
        }
        return fallbackDesign(agentId: agentId)
    }

    /// Deterministic fallback pick seeded from the agent id. Mirrors the
    /// desktop `stringToSeededRandom(agentId).pick(...)` (string hash + one
    /// LCG step) bit-for-bit: JS evaluates `seed * 1103515245 + 12345` in
    /// float64, losing low bits for seeds >= 2^22, and `& 0x7fffffff`
    /// applies ToUint32 — so the LCG step is computed in `Double` here
    /// rather than exact integer math.
    static func fallbackDesign(agentId: String) -> AgentAvatarDesign {
        var hash: Int32 = 0
        for unit in agentId.utf16 {
            hash = (hash &<< Constants.AgentAvatar.FallbackSelection.hashShift) &- hash &+ Int32(unit)
        }
        let product = Double(hash.magnitude) * Constants.AgentAvatar.FallbackSelection.multiplier
            + Constants.AgentAvatar.FallbackSelection.increment
        let wrapped = product.truncatingRemainder(
            dividingBy: Constants.AgentAvatar.FallbackSelection.modulus)
        let seed = UInt32(wrapped) & Constants.AgentAvatar.FallbackSelection.mask
        let index = Int(
            Double(seed) / Double(Constants.AgentAvatar.FallbackSelection.normalizationDivisor)
                * Double(fallbackDesigns.count))
        return fallbackDesigns[min(index, fallbackDesigns.count - 1)]
    }
}

/// Precomputed glyph geometry in the desktop 16×16 viewBox space.
struct AgentAvatarGlyph {
    var strokePath = Path()
    var fillPath = Path()
}

extension AgentAvatarDesign {
    var glyph: AgentAvatarGlyph { Self.glyphs[self] ?? AgentAvatarGlyph() }

    private static let glyphs: [AgentAvatarDesign: AgentAvatarGlyph] = {
        var glyphs: [AgentAvatarDesign: AgentAvatarGlyph] = [:]
        for design in AgentAvatarDesign.allCases {
            glyphs[design] = makeGlyph(design)
        }
        return glyphs
    }()

    // Path data below is verbatim from AgentAvatarArt.svelte (16×16 viewBox).
    private static func makeGlyph(_ design: AgentAvatarDesign) -> AgentAvatarGlyph {
        var stroke = Path()
        var fill = Path()
        var transform = CGAffineTransform.identity
        switch design {
        case .coordinator:
            transform = CGAffineTransform(translationX: -2, y: -2)
            stroke.addPath(Path(svgPathData: "M9.958 11.718V16.135M4.658 6.455L7.477 8.082C7.826 8.284 8.264 8.246 8.573 7.986C8.881 7.727 8.995 7.302 8.857 6.924L7.744 3.865M12.172 3.865L11.059 6.924C10.921 7.302 11.035 7.727 11.344 7.986C11.653 8.246 12.091 8.284 12.44 8.082L15.259 6.455M6.014 14.111L8.106 11.618C8.366 11.309 8.404 10.871 8.202 10.522C8.001 10.173 7.602 9.987 7.205 10.057L4 10.622M16 10.622L12.794 10.057C12.397 9.987 11.999 10.173 11.797 10.522C11.596 10.871 11.634 11.309 11.893 11.618L13.985 14.111"))
        case .implementor:
            stroke.addPath(Path(svgPathData: "M5.333 4.666H6C7.105 4.666 8 5.561 8 6.666V8.333M5.333 11.999H6C7.105 11.999 8 11.104 8 9.999V8.332M10.667 4.666H10C8.896 4.666 8 5.561 8 6.666V8.333M10.667 11.999H10C8.896 11.999 8 11.104 8 9.999V8.332"))
            stroke.addPath(Path(svgPathData: "M3.667 6L2.303 6.963C1.485 7.54 1.451 8.741 2.235 9.363L3.667 10.5M12.334 6L13.698 6.963C14.515 7.54 14.549 8.741 13.766 9.363L12.334 10.5"))
        case .verifier:
            stroke.addPath(Path(svgPathData: "M3.667 5.75L2.303 6.713C1.485 7.29 1.451 8.491 2.235 9.113L3.667 10.25M12.334 5.75L13.698 6.713C14.515 7.29 14.549 8.491 13.765 9.113L12.334 10.25M5.5 7.756L6.441 9.688C6.818 10.46 7.928 10.43 8.262 9.638L10.5 4.333"))
        case .prReviewer:
            stroke.addRoundedRect(
                in: CGRect(x: 6.333, y: 6.333, width: 3.334, height: 3.334),
                cornerSize: CGSize(width: 0.334, height: 0.334))
            stroke.addPath(Path(svgPathData: "M9 3H11C12.105 3 13 3.895 13 5V7M9 13H11C12.105 13 13 12.105 13 11V9M7 3H5C3.895 3 3 3.895 3 5V7M7 13H5C3.895 13 3 12.105 3 11V9"))
        case .uiDesigner:
            transform = CGAffineTransform(translationX: 1, y: 4.468)
            stroke.addPath(Path(svgPathData: "M4 .543L1.636 2.212C.818 2.789.784 3.99 1.568 4.612L4 6.543M10 .543L12.364 2.212C13.182 2.789 13.216 3.99 12.432 4.612L10 6.543"))
            fill.addEllipse(in: circleRect(cx: 7, cy: 3.543, r: 1.25))
        case .chiefOfStaff:
            transform = CGAffineTransform(translationX: 0.5, y: 4)
            stroke.addPath(Path(svgPathData: "M10 7.665H5M10 4.165H5M10 .665H5M3 2.165L1.636 3.128C.818 3.705.784 4.906 1.568 5.528L3 6.665M12 2.165L13.364 3.128C14.182 3.705 14.216 4.906 13.432 5.528L12 6.665"))
        case .ralph:
            transform = CGAffineTransform(translationX: 1, y: 3)
            stroke.addPath(Path(svgPathData: "M7 0V10M4 2L1.636 3.669C.818 4.246.784 5.447 1.568 6.069L4 8M10 2L12.364 3.669C13.182 4.246 13.216 5.447 12.432 6.069L10 8"))
        case .fallbackGlasses:
            transform = CGAffineTransform(translationX: 1, y: 5.335)
            stroke.addPath(Path(svgPathData: "M6 2.665H8M0 2.665H2M12 2.665H14"))
            stroke.addEllipse(in: circleRect(cx: 4, cy: 2.665, r: 2))
            stroke.addEllipse(in: circleRect(cx: 10, cy: 2.665, r: 2))
        case .fallbackCrown, .fallbackCrownInverted:
            transform = design == .fallbackCrown
                ? CGAffineTransform(translationX: 1, y: 2.918)
                : CGAffineTransform(translationX: 1, y: 13.082).scaledBy(x: 1, y: -1)
            stroke.addPath(Path(svgPathData: crownPathData))
            fill.addEllipse(in: circleRect(cx: 4.5, cy: 8.915, r: 1.25))
            fill.addEllipse(in: circleRect(cx: 9.5, cy: 8.915, r: 1.25))
        case .fallbackCrownMouth:
            transform = CGAffineTransform(translationX: 1, y: 3.085)
            stroke.addPath(Path(svgPathData: crownPathData + "M4 9.165H10"))
        case .fallbackCode:
            stroke.addPath(Path(svgPathData: "M13 4.5L10.636 6.169C9.818 6.746 9.784 7.947 10.568 8.569L13 10.5M3 4.5L5.364 6.169C6.182 6.746 6.216 7.947 5.432 8.569L3 10.5M6 11.5H10"))
        case .fallbackDots:
            transform = CGAffineTransform(translationX: 4, y: 6.5)
            fill.addEllipse(in: circleRect(cx: 1.5, cy: 1.5, r: 1.5))
            fill.addEllipse(in: circleRect(cx: 6.5, cy: 1.5, r: 1.5))
        }
        return AgentAvatarGlyph(
            strokePath: stroke.applying(transform),
            fillPath: fill.applying(transform))
    }

    private static let crownPathData = "M2 5.665L3.62 1.461C3.788.982 4.219.665 4.7.665C5.183.665 5.616.98 5.79 1.457L6.043 2.154C6.363 3.038 7.616 3.031 7.926 2.144L8.165 1.461C8.333.982 8.764.665 9.246.665C9.729.665 10.162.98 10.335 1.457L12 5.665M0 5.665H14"

    private static func circleRect(cx: CGFloat, cy: CGFloat, r: CGFloat) -> CGRect {
        CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
    }
}

extension Path {
    /// Parses absolute-command SVG path data — the M/L/H/V/C subset the
    /// desktop avatar glyphs use. Unsupported input stops parsing early.
    init(svgPathData data: String) {
        self.init()
        let chars = Array(data)
        var i = 0
        var command: Character = " "
        var current = CGPoint.zero

        func skipSeparators() {
            while i < chars.count, chars[i] == " " || chars[i] == "," { i += 1 }
        }

        func number() -> CGFloat? {
            skipSeparators()
            let start = i
            if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 }
            var seenDot = false
            var seenDigit = false
            while i < chars.count {
                let c = chars[i]
                if c == "." {
                    if seenDot { break }
                    seenDot = true
                } else if c >= "0", c <= "9" {
                    seenDigit = true
                } else {
                    break
                }
                i += 1
            }
            guard seenDigit else {
                i = start
                return nil
            }
            var text = String(chars[start..<i])
            if text.hasPrefix(".") { text = "0" + text }
            if text.hasPrefix("-.") { text = "-0" + text.dropFirst() }
            guard let value = Double(text) else {
                i = start
                return nil
            }
            return CGFloat(value)
        }

        func point() -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return CGPoint(x: x, y: y)
        }

        while true {
            skipSeparators()
            guard i < chars.count else { return }
            if chars[i].isLetter {
                command = chars[i]
                i += 1
            }
            switch command {
            case "M":
                guard let p = point() else { return }
                move(to: p)
                current = p
                command = "L"
            case "L":
                guard let p = point() else { return }
                addLine(to: p)
                current = p
            case "H":
                guard let x = number() else { return }
                current = CGPoint(x: x, y: current.y)
                addLine(to: current)
            case "V":
                guard let y = number() else { return }
                current = CGPoint(x: current.x, y: y)
                addLine(to: current)
            case "C":
                guard let c1 = point(), let c2 = point(), let p = point() else { return }
                addCurve(to: p, control1: c1, control2: c2)
                current = p
            default:
                return
            }
        }
    }
}
