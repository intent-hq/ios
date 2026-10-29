import UIKit

final class LineNumberTextContainer: UIView {
    let textView = LineNumberTextView()

    init() {
        super.init(frame: .zero)
        addSubview(textView)
        addSubview(textView.gutter)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = bounds
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
    }
}

final class LineNumberTextView: UITextView {
    private enum Layout {
        static let verticalPadding: CGFloat = 16
        static let horizontalPadding: CGFloat = 8
        static let gutterGap: CGFloat = 12
        static let minimumDigits = 2
    }

    let gutter = FileLineNumberGutter()
    private(set) var lineIndex = FileLineIndex("")
    private var wrapsLines = true
    private var unwrappedWidth: CGFloat = 0

    init() {
        super.init(frame: .zero, textContainer: nil)
        gutter.textView = self
        gutter.isUserInteractionEnabled = false
        gutter.isAccessibilityElement = false
        gutter.backgroundColor = .systemBackground
        gutter.numberPadding = Layout.gutterGap
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.lineBreakMode = .byWordWrapping
        isDirectionalLockEnabled = true
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self]) { (view: Self, _: UITraitCollection) in
            view.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override var contentSize: CGSize {
        get { super.contentSize }
        set {
            super.contentSize = CGSize(
                width: wrapsLines ? newValue.width : max(newValue.width, unwrappedWidth),
                height: newValue.height
            )
        }
    }

    func setSource(_ source: String, index: FileLineIndex? = nil) {
        unwrappedWidth = 0
        lineIndex = index ?? FileLineIndex(source)
        text = source
        setNeedsLayout()
    }

    func setWrapLines(_ enabled: Bool) {
        guard wrapsLines != enabled else { return }
        layoutIfNeeded()
        let selection = selectedRange
        let anchor = visibleLineLabels().first
        wrapsLines = enabled
        showsHorizontalScrollIndicator = !enabled
        setNeedsLayout()
        layoutIfNeeded()
        selectedRange = selection
        restoreAnchor(anchor)
    }

    private func restoreAnchor(_ anchor: LineLabel?) {
        var proposedY = contentOffset.y
        if let anchor, let manager = textLayoutManager, let content = manager.textContentManager,
           let location = content.location(content.documentRange.location, offsetBy: lineIndex.starts[anchor.number - 1]) {
            let origin = manager.textViewportLayoutController.relocateViewport(to: location)
            proposedY = origin + textContainerInset.top + numberFont.ascender - anchor.baseline
        }
        let maximumY = max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom)
        setContentOffset(CGPoint(x: 0, y: min(maximumY, max(-adjustedContentInset.top, proposedY))), animated: false)
        textLayoutManager?.textViewportLayoutController.layoutViewport()
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        let digits = max(Layout.minimumDigits, String(lineIndex.starts.count).count)
        let number = String(repeating: "8", count: digits)
        let width = ceil(number.size(withAttributes: [.font: numberFont]).width)
        let inset = UIEdgeInsets(
            top: Layout.verticalPadding,
            left: Layout.horizontalPadding + width + Layout.gutterGap,
            bottom: Layout.verticalPadding,
            right: Layout.horizontalPadding
        )
        if textContainerInset != inset { textContainerInset = inset }
        // Apply after receiving our frame, including a saved unwrapped preference on first presentation.
        let containerSize = CGSize(
            width: wrapsLines ? max(1, bounds.width - inset.left - inset.right) : .greatestFiniteMagnitude,
            height: .greatestFiniteMagnitude
        )
        if textContainer.size != containerSize { textContainer.size = containerSize }
        super.layoutSubviews()
        if !wrapsLines, let manager = textLayoutManager {
            unwrappedWidth = max(unwrappedWidth, manager.usageBoundsForTextContainer.maxX + inset.left + inset.right)
            let width = max(bounds.width, unwrappedWidth)
            if contentSize.width != width { contentSize.width = width }
        }
        gutter.frame = CGRect(x: 0, y: 0, width: inset.left, height: bounds.height)
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
        var start = viewport.location
        if !wrapsLines {
            // TextKit's horizontal viewport can exclude short source lines.
            let offset = content.offset(from: content.documentRange.location, to: start)
            let precedingRows = Int(ceil(bounds.height / numberFont.lineHeight)) + 1
            let firstLine = max(1, lineIndex.line(at: offset) - precedingRows)
            start = content.location(content.documentRange.location, offsetBy: lineIndex.starts[firstLine - 1]) ?? start
        }
        manager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout, .ensuresExtraLineFragment]) { fragment in
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

final class FileLineNumberGutter: UIView {
    weak var textView: LineNumberTextView?
    var numberPadding: CGFloat = 0

    override func draw(_: CGRect) {
        guard let textView else { return }
        let font = textView.numberFont
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.secondaryLabel]
        for label in textView.visibleLineLabels() {
            let number = String(label.number)
            let width = number.size(withAttributes: attributes).width
            number.draw(at: CGPoint(x: bounds.width - numberPadding - width, y: label.baseline - font.ascender), withAttributes: attributes)
        }
    }
}
