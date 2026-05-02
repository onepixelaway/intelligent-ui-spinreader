import SwiftUI
import UIKit

@MainActor
private func buildHighlightDisplayText(
    base: NSAttributedString,
    highlights: [Highlight],
    selectionRange: NSRange? = nil,
    playbackSentenceRange: NSRange? = nil,
    playbackWordRange: NSRange? = nil,
    pendingHighlight: Highlight? = nil,
    pendingOpacity: CGFloat = 0.25
) -> NSAttributedString {
    let mutable = NSMutableAttributedString(attributedString: base)
    for h in highlights {
        let range = NSRange(location: h.startOffset, length: h.endOffset - h.startOffset)
        guard range.location >= 0, NSMaxRange(range) <= mutable.length else { continue }
        mutable.addAttribute(
            .backgroundColor,
            value: h.displayUIColor.withAlphaComponent(0.30),
            range: range
        )
    }
    if let sel = selectionRange, sel.length > 0, sel.location >= 0, NSMaxRange(sel) <= mutable.length {
        mutable.addAttribute(.backgroundColor, value: UIColor.yellow.withAlphaComponent(0.25), range: sel)
    }
    if let playbackSentenceRange,
       playbackSentenceRange.length > 0,
       playbackSentenceRange.location >= 0,
       NSMaxRange(playbackSentenceRange) <= mutable.length {
        mutable.addAttribute(
            .backgroundColor,
            value: UIColor.white.withAlphaComponent(0.12),
            range: playbackSentenceRange
        )
    }
    if let playbackWordRange,
       playbackWordRange.length > 0,
       playbackWordRange.location >= 0,
       NSMaxRange(playbackWordRange) <= mutable.length {
        mutable.addAttribute(
            .backgroundColor,
            value: UIColor.systemBlue.withAlphaComponent(0.32),
            range: playbackWordRange
        )
    }
    if let pendingHighlight {
        let range = NSRange(location: pendingHighlight.startOffset, length: pendingHighlight.endOffset - pendingHighlight.startOffset)
        guard range.location >= 0, NSMaxRange(range) <= mutable.length else { return mutable }
        mutable.addAttribute(
            .backgroundColor,
            value: pendingHighlight.displayUIColor.withAlphaComponent(pendingOpacity),
            range: range
        )
    }
    return mutable
}

final class HighlightLayoutTextView: UITextView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

private enum EmojiMarginLayout {
    static let fontSize: CGFloat = 16
    static let labelSize: CGFloat = 22
    static let leftOffset: CGFloat = -28
    static let previewAlpha: CGFloat = 0.6
}

struct HighlightableTextView: UIViewRepresentable {
    let text: String
    let attributedText: NSAttributedString
    let itemIndex: Int
    let highlights: [Highlight]
    let playbackHighlight: PlaybackTextHighlight?
    let isPlaybackActive: Bool
    let pendingHighlight: Highlight?
    let pendingOpacity: CGFloat
    let showsPendingCursor: Bool
    let onHighlightCreated: (String, Int, Int) -> Void
    let onHighlightRemoved: (UUID) -> Void
    let onPlaybackWordTapped: (Int) -> Void
    let onEmptyTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = HighlightLayoutTextView()
        tv.isEditable = false
        tv.isSelectable = false
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.clipsToBounds = false
        tv.setContentHuggingPriority(.required, for: .vertical)
        tv.setContentCompressionResistancePriority(.required, for: .vertical)
        context.coordinator.installCursor(in: tv)

        tv.onLayout = { [weak tv] in
            guard let tv else { return }
            context.coordinator.updateEmojiMarginLabels(in: tv)
        }

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
        c.itemIndex = itemIndex
        c.playbackHighlight = playbackHighlight?.itemIndex == c.itemIndex ? playbackHighlight : nil
        c.isPlaybackActive = isPlaybackActive
        c.pendingHighlight = pendingHighlight
        c.pendingOpacity = pendingOpacity
        c.showsPendingCursor = showsPendingCursor
        c.text = text
        c.onHighlightCreated = onHighlightCreated
        c.onHighlightRemoved = onHighlightRemoved
        c.onPlaybackWordTapped = onPlaybackWordTapped
        c.onEmptyTap = onEmptyTap
        if c.isDragging { return }
        c.refreshDisplayText(in: tv)
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
        var playbackHighlight: PlaybackTextHighlight?
        var isPlaybackActive = false
        var itemIndex: Int?
        var pendingHighlight: Highlight?
        var pendingOpacity: CGFloat = 0.25
        var showsPendingCursor = false
        var text: String = ""
        var onHighlightCreated: ((String, Int, Int) -> Void)?
        var onHighlightRemoved: ((UUID) -> Void)?
        var onPlaybackWordTapped: ((Int) -> Void)?
        var onEmptyTap: () -> Void = {}
        var isDragging = false
        private var dragStart: Int?
        private let cursorView = UIView()
        private var emojiLabels: [UUID: UILabel] = [:]
        private var previewEmojiLabel: UILabel?

        func refreshDisplayText(in tv: UITextView) {
            tv.attributedText = buildHighlightDisplayText(
                base: baseAttributedText,
                highlights: highlights,
                playbackSentenceRange: playbackHighlight?.sentenceRange,
                playbackWordRange: playbackHighlight?.wordRange,
                pendingHighlight: pendingHighlight,
                pendingOpacity: pendingOpacity
            )
            updatePendingCursor(in: tv)
            updateEmojiMarginLabels(in: tv)
        }

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
            cursorView.backgroundColor = pendingHighlight.displayUIColor
            cursorView.frame = CGRect(
                x: glyphRect.maxX + tv.textContainerInset.left + 1,
                y: lineRect.midY - height / 2 + tv.textContainerInset.top,
                width: 2,
                height: height
            )
            cursorView.isHidden = false
        }

        func updateEmojiMarginLabels(in tv: UITextView) {
            let hasEmojiHighlight = highlights.contains { $0.emoji != nil }
            let hasPendingEmoji = pendingHighlight?.emoji != nil
            if !hasEmojiHighlight && !hasPendingEmoji && emojiLabels.isEmpty && previewEmojiLabel == nil {
                return
            }

            var activeIDs: Set<UUID> = []
            for h in highlights where h.emoji != nil {
                activeIDs.insert(h.id)
            }

            for (id, label) in emojiLabels where !activeIDs.contains(id) {
                label.removeFromSuperview()
                emojiLabels.removeValue(forKey: id)
            }

            tv.layoutManager.ensureLayout(for: tv.textContainer)

            for h in highlights {
                guard let emoji = h.emoji else { continue }
                guard let firstLineRect = firstLineRect(in: tv, startOffset: h.startOffset, endOffset: h.endOffset) else {
                    emojiLabels[h.id]?.isHidden = true
                    continue
                }
                let label = emojiLabels[h.id] ?? makeEmojiLabel(in: tv)
                emojiLabels[h.id] = label
                positionEmojiLabel(label, emoji: emoji, firstLineRect: firstLineRect)
            }

            updatePreviewEmojiLabel(in: tv)
        }

        private func updatePreviewEmojiLabel(in tv: UITextView) {
            guard let pending = pendingHighlight,
                  let emoji = pending.emoji,
                  let firstLineRect = firstLineRect(in: tv, startOffset: pending.startOffset, endOffset: pending.endOffset) else {
                previewEmojiLabel?.removeFromSuperview()
                previewEmojiLabel = nil
                return
            }

            let label = previewEmojiLabel ?? makeEmojiLabel(in: tv, alpha: EmojiMarginLayout.previewAlpha)
            previewEmojiLabel = label
            positionEmojiLabel(label, emoji: emoji, firstLineRect: firstLineRect)
        }

        private func makeEmojiLabel(in tv: UITextView, alpha: CGFloat = 1.0) -> UILabel {
            let label = UILabel()
            label.font = UIFont.systemFont(ofSize: EmojiMarginLayout.fontSize)
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = false
            label.alpha = alpha
            tv.addSubview(label)
            return label
        }

        private func positionEmojiLabel(_ label: UILabel, emoji: String, firstLineRect: CGRect) {
            label.text = emoji
            label.isHidden = false
            let size = EmojiMarginLayout.labelSize
            label.frame = CGRect(
                x: EmojiMarginLayout.leftOffset,
                y: firstLineRect.midY - size / 2,
                width: size,
                height: size
            )
        }

        private func firstLineRect(in tv: UITextView, startOffset: Int, endOffset: Int) -> CGRect? {
            let nsLength = tv.attributedText.length
            guard startOffset >= 0, endOffset <= nsLength, startOffset < endOffset else { return nil }
            let range = NSRange(location: startOffset, length: endOffset - startOffset)
            let layoutManager = tv.layoutManager
            let container = tv.textContainer
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return nil }

            var firstFragment: CGRect?
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, stop in
                firstFragment = usedRect
                stop.pointee = true
            }

            let inset = tv.textContainerInset
            if let used = firstFragment {
                return CGRect(
                    x: used.minX + inset.left,
                    y: used.minY + inset.top,
                    width: used.width,
                    height: used.height
                )
            }

            let bounding = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            guard !bounding.isNull, !bounding.isEmpty else { return nil }
            return CGRect(
                x: bounding.minX + inset.left,
                y: bounding.minY + inset.top,
                width: bounding.width,
                height: bounding.height
            )
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
                    selectionRange: NSRange(location: loc, length: len),
                    playbackSentenceRange: playbackHighlight?.sentenceRange,
                    playbackWordRange: playbackHighlight?.wordRange
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
                refreshDisplayText(in: tv)
            default:
                isDragging = false
                dragStart = nil
                refreshDisplayText(in: tv)
            }
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let tv = g.view as? UITextView else { return }
            let pt = g.location(in: tv)
            let idx = charIndex(at: pt, in: tv)

            if isPlaybackActive, let range = wordRange(containingOrAdjacentTo: idx) {
                onPlaybackWordTapped?(range.location)
                return
            }

            for h in highlights where idx >= h.startOffset && idx < h.endOffset {
                onHighlightRemoved?(h.id)
                return
            }

            onEmptyTap()
        }

        private func wordRange(containingOrAdjacentTo index: Int) -> NSRange? {
            let nsText = text as NSString
            guard nsText.length > 0 else { return nil }
            let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
            var probe = min(max(0, index), nsText.length - 1)

            if isSeparator(at: probe, in: nsText, separators: separators) {
                let previous = probe - 1
                if previous >= 0, !isSeparator(at: previous, in: nsText, separators: separators) {
                    probe = previous
                } else {
                    return nil
                }
            }

            var start = probe
            while start > 0, !isSeparator(at: start - 1, in: nsText, separators: separators) {
                start -= 1
            }

            var end = probe + 1
            while end < nsText.length, !isSeparator(at: end, in: nsText, separators: separators) {
                end += 1
            }

            guard end > start else { return nil }
            return NSRange(location: start, length: end - start)
        }

        private func isSeparator(at index: Int, in nsText: NSString, separators: CharacterSet) -> Bool {
            guard index >= 0, index < nsText.length else { return true }
            let character = nsText.substring(with: NSRange(location: index, length: 1))
            return character.rangeOfCharacter(from: separators) != nil
        }
    }
}
