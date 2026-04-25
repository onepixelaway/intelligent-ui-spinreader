import SwiftUI
import UIKit

private func buildHighlightDisplayText(
    base: NSAttributedString,
    highlights: [Highlight],
    selectionRange: NSRange? = nil,
    pendingHighlight: Highlight? = nil,
    pendingOpacity: CGFloat = 0.25
) -> NSAttributedString {
    let mutable = NSMutableAttributedString(attributedString: base)
    for h in highlights {
        let range = NSRange(location: h.startOffset, length: h.endOffset - h.startOffset)
        guard range.location >= 0, NSMaxRange(range) <= mutable.length else { continue }
        mutable.addAttribute(
            .backgroundColor,
            value: highlightUIColor(for: h.color).withAlphaComponent(0.30),
            range: range
        )
    }
    if let sel = selectionRange, sel.length > 0, sel.location >= 0, NSMaxRange(sel) <= mutable.length {
        mutable.addAttribute(.backgroundColor, value: UIColor.yellow.withAlphaComponent(0.25), range: sel)
    }
    if let pendingHighlight {
        let range = NSRange(location: pendingHighlight.startOffset, length: pendingHighlight.endOffset - pendingHighlight.startOffset)
        guard range.location >= 0, NSMaxRange(range) <= mutable.length else { return mutable }
        let color = highlightUIColor(for: pendingHighlight.color)
        mutable.addAttribute(
            .backgroundColor,
            value: color.withAlphaComponent(pendingOpacity),
            range: range
        )
    }
    return mutable
}

private func highlightUIColor(for color: String) -> UIColor {
    HighlightColorChoice(rawValue: color)?.uiColor ?? HighlightColorChoice.yellow.uiColor
}

struct HighlightableTextView: UIViewRepresentable {
    let text: String
    let attributedText: NSAttributedString
    let highlights: [Highlight]
    let pendingHighlight: Highlight?
    let pendingOpacity: CGFloat
    let showsPendingCursor: Bool
    let onHighlightCreated: (String, Int, Int) -> Void
    let onHighlightRemoved: (UUID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = false
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.setContentHuggingPriority(.required, for: .vertical)
        tv.setContentCompressionResistancePriority(.required, for: .vertical)
        context.coordinator.installCursor(in: tv)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        tv.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tv.addGestureRecognizer(tap)

        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let c = context.coordinator
        c.baseAttributedText = attributedText
        c.highlights = highlights
        c.pendingHighlight = pendingHighlight
        c.pendingOpacity = pendingOpacity
        c.showsPendingCursor = showsPendingCursor
        c.text = text
        c.onHighlightCreated = onHighlightCreated
        c.onHighlightRemoved = onHighlightRemoved
        if c.isDragging { return }
        tv.attributedText = buildHighlightDisplayText(
            base: attributedText,
            highlights: highlights,
            pendingHighlight: pendingHighlight,
            pendingOpacity: pendingOpacity
        )
        c.updatePendingCursor(in: tv)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingCompressedSize.width
        let size = uiView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }

    @MainActor
    final class Coordinator: NSObject {
        var baseAttributedText = NSAttributedString()
        var highlights: [Highlight] = []
        var pendingHighlight: Highlight?
        var pendingOpacity: CGFloat = 0.25
        var showsPendingCursor = false
        var text: String = ""
        var onHighlightCreated: ((String, Int, Int) -> Void)?
        var onHighlightRemoved: ((UUID) -> Void)?
        var isDragging = false
        private var dragStart: Int?
        private let cursorView = UIView()

        func installCursor(in tv: UITextView) {
            cursorView.isHidden = true
            cursorView.layer.cornerRadius = 1
            tv.addSubview(cursorView)
        }

        func updatePendingCursor(in tv: UITextView) {
            guard showsPendingCursor,
                  let pendingHighlight,
                  tv.attributedText.length > 0 else {
                cursorView.isHidden = true
                return
            }
            let insertionIndex = min(max(1, pendingHighlight.endOffset), tv.attributedText.length)
            let previousCharacterRange = NSRange(location: insertionIndex - 1, length: 1)
            let layoutManager = tv.layoutManager
            let textContainer = tv.textContainer
            layoutManager.ensureLayout(for: textContainer)

            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: previousCharacterRange,
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else {
                cursorView.isHidden = true
                return
            }

            let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            let lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            let height = max(12, min(lineRect.height, glyphRect.height * 1.25))
            cursorView.backgroundColor = highlightUIColor(for: pendingHighlight.color)
            cursorView.frame = CGRect(
                x: glyphRect.maxX + tv.textContainerInset.left + 1,
                y: lineRect.midY - height / 2 + tv.textContainerInset.top,
                width: 2,
                height: height
            )
            cursorView.isHidden = false
        }

        // Returns a UTF-16 index (NSString length units), matching NSRange math and Highlight.startOffset/endOffset.
        private func charIndex(at point: CGPoint, in tv: UITextView) -> Int {
            let layoutManager = tv.layoutManager
            let textContainer = tv.textContainer
            let inset = tv.textContainerInset
            let p = CGPoint(x: point.x - inset.left, y: point.y - inset.top)
            let idx = layoutManager.characterIndex(for: p, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
            return min(idx, (tv.text as NSString?)?.length ?? 0)
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let tv = g.view as? UITextView else { return }
            let pt = g.location(in: tv)

            switch g.state {
            case .began:
                isDragging = true
                dragStart = charIndex(at: pt, in: tv)
            case .changed:
                guard let start = dragStart else { return }
                let current = charIndex(at: pt, in: tv)
                let loc = min(start, current)
                let len = abs(current - start)
                tv.attributedText = buildHighlightDisplayText(
                    base: baseAttributedText,
                    highlights: highlights,
                    selectionRange: NSRange(location: loc, length: len)
                )
                cursorView.isHidden = true
            case .ended:
                guard let start = dragStart else { return }
                let end = charIndex(at: pt, in: tv)
                let loc = min(start, end)
                let len = abs(end - start)
                if len > 0 {
                    let nsText = (text as NSString)
                    let range = NSRange(location: loc, length: min(len, nsText.length - loc))
                    if range.length > 0, NSMaxRange(range) <= nsText.length {
                        let selectedText = nsText.substring(with: range)
                        onHighlightCreated?(selectedText, loc, loc + range.length)
                    }
                }
                isDragging = false
                dragStart = nil
                tv.attributedText = buildHighlightDisplayText(
                    base: baseAttributedText,
                    highlights: highlights,
                    pendingHighlight: pendingHighlight,
                    pendingOpacity: pendingOpacity
                )
                updatePendingCursor(in: tv)
            default:
                isDragging = false
                dragStart = nil
                tv.attributedText = buildHighlightDisplayText(
                    base: baseAttributedText,
                    highlights: highlights,
                    pendingHighlight: pendingHighlight,
                    pendingOpacity: pendingOpacity
                )
                updatePendingCursor(in: tv)
            }
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let tv = g.view as? UITextView else { return }
            let pt = g.location(in: tv)
            let idx = charIndex(at: pt, in: tv)

            for h in highlights where idx >= h.startOffset && idx < h.endOffset {
                onHighlightRemoved?(h.id)
                return
            }
        }
    }
}
