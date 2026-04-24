import SwiftUI
import UIKit
import NaturalLanguage

extension ScrollTextView {
    struct AutoHighlightSelection {
        let itemIndex: Int
        let sentenceRange: ClosedRange<Int>?
        let highlightIDs: [UUID]
    }

    enum AutoHighlightUpdate {
        case none
        case changed(shouldAdvancePage: Bool)
    }

    private struct HighlightContext {
        let index: Int
        let text: String
        let cid: String
        let sentences: [(text: String, start: Int, end: Int)]
        let viewport: CGRect
    }

    private struct HighlightTarget {
        let selection: AutoHighlightSelection
        let highlights: [Highlight]
        let shouldAdvancePage: Bool
    }

    private struct TextLayoutContext {
        let layoutManager: NSLayoutManager
        let textContainer: NSTextContainer
        let frame: CGRect
    }

    func contentIDForItem(at index: Int) -> String {
        guard index < itemContentIDs.count else { return contentID }
        return itemContentIDs[index]
    }

    func highlightsForParagraph(_ text: String, itemIndex: Int) -> [Highlight] {
        let cid = contentIDForItem(at: itemIndex)
        let nsText = text as NSString
        return highlightStore.highlights(for: cid).filter { h in
            guard h.startOffset >= 0, h.endOffset <= nsText.length, h.startOffset < h.endOffset else { return false }
            return nsText.substring(with: NSRange(location: h.startOffset, length: h.endOffset - h.startOffset)) == h.text
        }
    }

    func cycleHighlightForTopVisibleParagraph(
        viewportWidth: CGFloat,
        scrollViewHeight: CGFloat,
        topFadeHeight: CGFloat
    ) -> AutoHighlightUpdate {
        let viewport = highlightViewport(
            viewportWidth: viewportWidth,
            scrollViewHeight: scrollViewHeight,
            topFadeHeight: topFadeHeight
        )
        guard viewport.width > 0, viewport.height > 0 else { return .none }

        let target: HighlightTarget?
        if let selection = autoHighlightSelection, shouldContinueAutoHighlight(selection, viewport: viewport) {
            target = nextHighlightTarget(after: selection, viewport: viewport)
        } else {
            target = startingHighlightTarget(viewport: viewport)
        }

        guard let target else { return .none }
        applyAutoHighlightTarget(target)
        return .changed(shouldAdvancePage: target.shouldAdvancePage)
    }

    func extendHighlightForTopVisibleParagraph(
        viewportWidth: CGFloat,
        scrollViewHeight: CGFloat,
        topFadeHeight: CGFloat
    ) -> AutoHighlightUpdate {
        let viewport = highlightViewport(
            viewportWidth: viewportWidth,
            scrollViewHeight: scrollViewHeight,
            topFadeHeight: topFadeHeight
        )
        guard viewport.width > 0, viewport.height > 0 else { return .none }

        guard let selection = autoHighlightSelection,
              shouldContinueAutoHighlight(selection, viewport: viewport),
              items.indices.contains(selection.itemIndex),
              items[selection.itemIndex].isHighlightableBody else {
            return cycleHighlightForTopVisibleParagraph(
                viewportWidth: viewportWidth,
                scrollViewHeight: scrollViewHeight,
                topFadeHeight: topFadeHeight
            )
        }

        guard let target = extendedHighlightTarget(from: selection, viewport: viewport) else {
            return .none
        }
        applyAutoHighlightTarget(target)
        return .changed(shouldAdvancePage: target.shouldAdvancePage)
    }

    private func highlightViewport(
        viewportWidth: CGFloat,
        scrollViewHeight: CGFloat,
        topFadeHeight: CGFloat
    ) -> CGRect {
        CGRect(
            x: 0,
            y: topFadeHeight,
            width: viewportWidth,
            height: max(0, scrollViewHeight - topFadeHeight)
        )
    }

    private func resolveHighlightContext(viewport: CGRect) -> HighlightContext? {
        guard let index = pickHighlightTarget(viewport: viewport) else { return nil }
        return resolveHighlightContext(for: index, viewport: viewport)
    }

    private func resolveHighlightContext(for index: Int, viewport: CGRect) -> HighlightContext? {
        guard items.indices.contains(index) else { return nil }
        let item = items[index]
        guard item.isHighlightableBody || item.isWholeItemHighlightable else { return nil }

        let text = renderedAttributedText(for: item)?.string ?? textForAnalysis(item)
        guard !text.isEmpty else { return nil }
        let cid = contentIDForItem(at: index)
        let sentences = item.isHighlightableBody ? tokenizeSentences(in: text) : []
        return HighlightContext(index: index, text: text, cid: cid, sentences: sentences, viewport: viewport)
    }

    private func shouldContinueAutoHighlight(_ selection: AutoHighlightSelection, viewport: CGRect) -> Bool {
        guard items.indices.contains(selection.itemIndex) else { return false }
        let item = items[selection.itemIndex]
        let cid = contentIDForItem(at: selection.itemIndex)
        let activeHighlightIDs = Set(highlightStore.highlights(for: cid).map(\.id))
        guard !selection.highlightIDs.isEmpty,
              selection.highlightIDs.allSatisfy(activeHighlightIDs.contains) else { return false }

        if item.isHighlightableBody,
           let sentenceRange = selection.sentenceRange,
           let ctx = resolveHighlightContext(for: selection.itemIndex, viewport: viewport) {
            return sentenceRange.lowerBound >= 0 && sentenceRange.upperBound < ctx.sentences.count
        }

        if item.isWholeItemHighlightable {
            return true
        }

        return false
    }

    private func pickHighlightTarget(viewport: CGRect) -> Int? {
        let epsilon: CGFloat = 1
        let eligibleFrames = paragraphFrames
            .compactMap { index, frame -> (index: Int, frame: CGRect)? in
                guard items.indices.contains(index),
                      items[index].isHighlightableBody || items[index].isWholeItemHighlightable,
                      frame.height > 0 else { return nil }
                return (index, frame)
            }
            .sorted {
                if abs($0.frame.minY - $1.frame.minY) > 0.5 {
                    return $0.frame.minY < $1.frame.minY
                }
                return $0.index < $1.index
            }

        if let currentTop = eligibleFrames.first(where: { candidate in
            candidate.frame.minY <= viewport.minY + epsilon && candidate.frame.maxY > viewport.minY + epsilon
        }) {
            return currentTop.index
        }

        if let nextVisible = eligibleFrames.first(where: { candidate in
            candidate.frame.minY >= viewport.minY && candidate.frame.minY < viewport.maxY
        }) {
            return nextVisible.index
        }

        return eligibleFrames.first(where: { viewport.intersects($0.frame) })?.index
    }

    private func startingHighlightTarget(viewport: CGRect) -> HighlightTarget? {
        guard let ctx = resolveHighlightContext(viewport: viewport) else { return nil }
        if items[ctx.index].isWholeItemHighlightable {
            return wholeItemHighlightTarget(ctx: ctx, viewport: viewport)
        }
        guard !ctx.sentences.isEmpty else { return nil }
        let sentenceIndex = startingSentenceIndex(itemIndex: ctx.index, viewport: viewport, sentences: ctx.sentences)
        return sentenceHighlightTarget(ctx: ctx, sentenceRange: sentenceIndex...sentenceIndex, viewport: viewport)
    }

    private func nextHighlightTarget(after selection: AutoHighlightSelection, viewport: CGRect) -> HighlightTarget? {
        guard items.indices.contains(selection.itemIndex) else { return nil }

        if items[selection.itemIndex].isHighlightableBody,
           let sentenceRange = selection.sentenceRange,
           let ctx = resolveHighlightContext(for: selection.itemIndex, viewport: viewport) {
            let nextSentenceIndex = sentenceRange.upperBound + 1
            if nextSentenceIndex < ctx.sentences.count {
                return sentenceHighlightTarget(
                    ctx: ctx,
                    sentenceRange: nextSentenceIndex...nextSentenceIndex,
                    viewport: viewport
                )
            }
        }

        return nextHighlightTarget(afterItemIndex: selection.itemIndex, viewport: viewport)
    }

    private func nextHighlightTarget(afterItemIndex itemIndex: Int, viewport: CGRect) -> HighlightTarget? {
        for nextIndex in items.indices where nextIndex > itemIndex {
            guard let ctx = resolveHighlightContext(for: nextIndex, viewport: viewport) else { continue }
            if items[nextIndex].isWholeItemHighlightable {
                return wholeItemHighlightTarget(ctx: ctx, viewport: viewport)
            }
            if !ctx.sentences.isEmpty {
                return sentenceHighlightTarget(ctx: ctx, sentenceRange: 0...0, viewport: viewport)
            }
        }
        return nil
    }

    private func extendedHighlightTarget(
        from selection: AutoHighlightSelection,
        viewport: CGRect
    ) -> HighlightTarget? {
        guard let sentenceRange = selection.sentenceRange,
              let ctx = resolveHighlightContext(for: selection.itemIndex, viewport: viewport) else { return nil }
        let nextSentenceIndex = sentenceRange.upperBound + 1
        guard nextSentenceIndex < ctx.sentences.count else { return nil }
        return sentenceHighlightTarget(
            ctx: ctx,
            sentenceRange: sentenceRange.lowerBound...nextSentenceIndex,
            viewport: viewport
        )
    }

    private func sentenceHighlightTarget(
        ctx: HighlightContext,
        sentenceRange: ClosedRange<Int>,
        viewport: CGRect
    ) -> HighlightTarget? {
        guard sentenceRange.lowerBound >= 0,
              sentenceRange.upperBound < ctx.sentences.count else { return nil }

        let startSentence = ctx.sentences[sentenceRange.lowerBound]
        let endSentence = ctx.sentences[sentenceRange.upperBound]
        let nsText = ctx.text as NSString
        let combinedRange = NSRange(location: startSentence.start, length: endSentence.end - startSentence.start)
        guard combinedRange.length > 0, NSMaxRange(combinedRange) <= nsText.length else { return nil }

        let highlightText = nsText.substring(with: combinedRange)
        let highlight = Highlight(
            contentID: ctx.cid,
            text: highlightText,
            startOffset: startSentence.start,
            endOffset: endSentence.end
        )
        let shouldAdvancePage = (highlightRect(for: sentenceRange, in: ctx)?.minY ?? -.greatestFiniteMagnitude) >= viewport.maxY - 0.5
        return HighlightTarget(
            selection: AutoHighlightSelection(
                itemIndex: ctx.index,
                sentenceRange: sentenceRange,
                highlightIDs: [highlight.id]
            ),
            highlights: [highlight],
            shouldAdvancePage: shouldAdvancePage
        )
    }

    private func wholeItemHighlightTarget(ctx: HighlightContext, viewport: CGRect) -> HighlightTarget? {
        let endOffset = (ctx.text as NSString).length
        guard endOffset > 0 else { return nil }
        let highlight = Highlight(contentID: ctx.cid, text: ctx.text, startOffset: 0, endOffset: endOffset)
        let shouldAdvancePage = (paragraphFrames[ctx.index]?.minY ?? -.greatestFiniteMagnitude) >= viewport.maxY - 0.5
        return HighlightTarget(
            selection: AutoHighlightSelection(itemIndex: ctx.index, sentenceRange: nil, highlightIDs: [highlight.id]),
            highlights: [highlight],
            shouldAdvancePage: shouldAdvancePage
        )
    }

    private func applyAutoHighlightTarget(_ target: HighlightTarget) {
        if let existing = autoHighlightSelection?.highlightIDs, !existing.isEmpty {
            highlightStore.removeBatch(ids: Set(existing))
        }
        highlightStore.addBatch(target.highlights)
        autoHighlightSelection = target.selection
    }

    private func textLayoutContext(for itemIndex: Int, viewport: CGRect) -> TextLayoutContext? {
        guard items.indices.contains(itemIndex),
              let frame = paragraphFrames[itemIndex],
              frame.height > 0 else { return nil }
        let item = items[itemIndex]
        guard let attributedText = renderedAttributedText(for: item) else { return nil }

        let paragraphWidth = viewport.width - 2 * horizontalPadding(for: item)
        guard paragraphWidth > 0 else { return nil }

        let textStorage = NSTextStorage(attributedString: attributedText)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: paragraphWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        _ = layoutManager.glyphRange(for: container)

        return TextLayoutContext(layoutManager: layoutManager, textContainer: container, frame: frame)
    }

    private func highlightRect(
        for sentenceRange: ClosedRange<Int>,
        in ctx: HighlightContext
    ) -> CGRect? {
        guard let layout = textLayoutContext(for: ctx.index, viewport: ctx.viewport) else { return nil }
        let startOffset = ctx.sentences[sentenceRange.lowerBound].start
        let endOffset = ctx.sentences[sentenceRange.upperBound].end
        let characterRange = NSRange(location: startOffset, length: endOffset - startOffset)
        guard characterRange.length > 0 else { return nil }

        let glyphRange = layout.layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        var rect = CGRect.null
        layout.layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, _ in
            rect = rect.union(usedRect)
        }
        if rect.isNull || rect.isEmpty {
            rect = layout.layoutManager.boundingRect(forGlyphRange: glyphRange, in: layout.textContainer)
        }
        guard !rect.isNull, !rect.isEmpty else { return nil }

        return CGRect(
            x: layout.frame.minX + rect.minX,
            y: layout.frame.minY + rect.minY,
            width: rect.width,
            height: rect.height
        )
    }

    private func firstVisibleCharacterIndex(itemIndex: Int, viewport: CGRect, text: String) -> Int? {
        guard let frame = paragraphFrames[itemIndex],
              let layout = textLayoutContext(for: itemIndex, viewport: viewport) else { return nil }

        let visibleTop = max(0, viewport.minY - frame.minY)
        let visibleBottom = min(frame.height, max(visibleTop + 1, viewport.maxY - frame.minY))
        guard visibleBottom > visibleTop else { return nil }

        let visibleRect = CGRect(
            x: 0,
            y: visibleTop,
            width: layout.textContainer.size.width,
            height: visibleBottom - visibleTop
        )
        let glyphRange = layout.layoutManager.glyphRange(forBoundingRect: visibleRect, in: layout.textContainer)
        guard glyphRange.length > 0 else { return nil }

        let charRange = layout.layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let nsText = text as NSString
        guard nsText.length > 0 else { return nil }

        let start = min(max(0, charRange.location), max(0, nsText.length - 1))
        let end = min(NSMaxRange(charRange), nsText.length)
        guard end > start else { return start }

        let visibleRange = NSRange(location: start, length: end - start)
        let firstNonWhitespace = nsText.rangeOfCharacter(
            from: CharacterSet.whitespacesAndNewlines.inverted,
            options: [],
            range: visibleRange
        )
        if firstNonWhitespace.location != NSNotFound {
            return firstNonWhitespace.location
        }
        return visibleRange.location
    }

    private func tokenizeSentences(in text: String) -> [(text: String, start: Int, end: Int)] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [(text: String, start: Int, end: Int)] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let raw = String(text[range])
            guard raw.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5 else { return true }
            let start = range.lowerBound.utf16Offset(in: text)
            let end = range.upperBound.utf16Offset(in: text)
            result.append((raw, start, end))
            return true
        }
        return result
    }

    private func startingSentenceIndex(
        itemIndex: Int,
        viewport: CGRect,
        sentences: [(text: String, start: Int, end: Int)]
    ) -> Int {
        guard !sentences.isEmpty else { return 0 }
        guard let ctx = resolveHighlightContext(for: itemIndex, viewport: viewport) else { return 0 }

        if let probeIndex = firstVisibleCharacterIndex(itemIndex: itemIndex, viewport: viewport, text: ctx.text),
           let sentenceIndex = sentences.firstIndex(where: { probeIndex >= $0.start && probeIndex < $0.end }) {
            return sentenceIndex
        }

        guard let frame = paragraphFrames[itemIndex], frame.height > 0 else { return 0 }
        if frame.minY >= viewport.minY {
            return 0
        }

        if let layout = textLayoutContext(for: itemIndex, viewport: viewport) {
            let effectiveTopInParagraph = viewport.minY - frame.minY
            for (idx, sentence) in sentences.enumerated() {
                let glyphIdx = layout.layoutManager.glyphIndexForCharacter(at: sentence.start)
                let lineRect = layout.layoutManager.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
                if lineRect.minY >= effectiveTopInParagraph {
                    return idx
                }
            }
        }

        if let lastVisibleSentence = sentences.indices.last {
            let lastSentence = sentences[lastVisibleSentence]
            if lastSentence.start < (ctx.text as NSString).length {
                return lastVisibleSentence
            }
        }
        return 0
    }
}

