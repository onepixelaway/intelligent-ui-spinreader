import SwiftUI
import UIKit

private func buildHighlightDisplayText(
    base: NSAttributedString,
    highlights: [Highlight],
    selectionRange: NSRange? = nil
) -> NSAttributedString {
    let mutable = NSMutableAttributedString(attributedString: base)
    for h in highlights {
        let range = NSRange(location: h.startOffset, length: h.endOffset - h.startOffset)
        guard range.location >= 0, NSMaxRange(range) <= mutable.length else { continue }
        mutable.addAttribute(.backgroundColor, value: UIColor.yellow.withAlphaComponent(0.3), range: range)
    }
    if let sel = selectionRange, sel.length > 0, sel.location >= 0, NSMaxRange(sel) <= mutable.length {
        mutable.addAttribute(.backgroundColor, value: UIColor.yellow.withAlphaComponent(0.25), range: sel)
    }
    return mutable
}

struct HighlightableTextView: UIViewRepresentable {
    let text: String
    let attributedText: NSAttributedString
    let highlights: [Highlight]
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
        c.text = text
        c.onHighlightCreated = onHighlightCreated
        c.onHighlightRemoved = onHighlightRemoved
        if c.isDragging { return }
        tv.attributedText = buildHighlightDisplayText(base: attributedText, highlights: highlights)
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
        var text: String = ""
        var onHighlightCreated: ((String, Int, Int) -> Void)?
        var onHighlightRemoved: ((UUID) -> Void)?
        var isDragging = false
        private var dragStart: Int?

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
                tv.attributedText = buildHighlightDisplayText(base: baseAttributedText, highlights: highlights)
            default:
                isDragging = false
                dragStart = nil
                tv.attributedText = buildHighlightDisplayText(base: baseAttributedText, highlights: highlights)
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
