import UIKit

final class LineNumberTextView: UITextView {
    private enum Layout {
        static let padding: CGFloat = 16
        static let gutterGap: CGFloat = 12
        static let minimumDigits = 2
    }

    private let gutter = FileLineNumberGutter()
    private(set) var lineIndex = FileLineIndex("")

    init() {
        super.init(frame: .zero, textContainer: nil)
        gutter.textView = self
        gutter.isUserInteractionEnabled = false
        gutter.isAccessibilityElement = false
        gutter.backgroundColor = .clear
        addSubview(gutter)
        textContainer.lineFragmentPadding = 0
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self]) { (view: Self, _: UITraitCollection) in
            view.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    func setSource(_ source: String, index: FileLineIndex? = nil) {
        lineIndex = index ?? FileLineIndex(source)
        text = source
        setNeedsLayout()
    }

    override func layoutSubviews() {
        let digits = max(Layout.minimumDigits, String(lineIndex.starts.count).count)
        let number = String(repeating: "8", count: digits)
        let width = ceil(number.size(withAttributes: [.font: numberFont]).width)
        let inset = UIEdgeInsets(
            top: Layout.padding,
            left: Layout.padding + width + Layout.gutterGap,
            bottom: Layout.padding,
            right: Layout.padding
        )
        if textContainerInset != inset { textContainerInset = inset }
        super.layoutSubviews()
        gutter.frame = CGRect(x: bounds.minX, y: bounds.minY, width: Layout.padding + width, height: bounds.height)
        bringSubviewToFront(gutter)
        gutter.setNeedsDisplay()
    }

    var numberFont: UIFont {
        font ?? .monospacedSystemFont(ofSize: UIFont.systemFontSize, weight: .regular)
    }

    struct LineLabel {
        let number: Int
        let baseline: CGFloat
    }

    func visibleLineLabels() -> [LineLabel] {
        if text.isEmpty {
            return [LineLabel(number: 1, baseline: textContainerInset.top - bounds.minY + numberFont.ascender)]
        }
        guard let manager = textLayoutManager,
              let content = manager.textContentManager,
              let viewport = manager.textViewportLayoutController.viewportRange else { return [] }
        var labels: [LineLabel] = []
        manager.enumerateTextLayoutFragments(from: viewport.location, options: [.ensuresExtraLineFragment]) { fragment in
            guard fragment.rangeInElement.location.compare(viewport.endLocation) != .orderedDescending else { return false }
            let origin = fragment.layoutFragmentFrame.minY + self.textContainerInset.top - self.bounds.minY
            guard origin <= self.bounds.height else { return false }
            let elementStart = fragment.textElement?.elementRange?.location ?? fragment.rangeInElement.location
            let offset = content.offset(from: content.documentRange.location, to: elementStart)
            for line in fragment.textLineFragments {
                let position = offset + line.characterRange.location
                let number = self.lineIndex.line(at: position)
                guard self.lineIndex.starts[number - 1] == position else { continue }
                let baseline = origin + line.typographicBounds.minY + line.glyphOrigin.y
                if baseline >= 0, baseline <= self.bounds.height + self.numberFont.lineHeight {
                    labels.append(LineLabel(number: number, baseline: baseline))
                }
            }
            return true
        }
        return labels
    }
}

private final class FileLineNumberGutter: UIView {
    weak var textView: LineNumberTextView?

    override func draw(_: CGRect) {
        guard let textView else { return }
        let font = textView.numberFont
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.secondaryLabel]
        for label in textView.visibleLineLabels() {
            let number = String(label.number)
            let width = number.size(withAttributes: attributes).width
            number.draw(at: CGPoint(x: bounds.width - width, y: label.baseline - font.ascender), withAttributes: attributes)
        }
    }
}
