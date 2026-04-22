import SwiftUI
import UIKit
import NaturalLanguage

extension ScrollTextView {
    private struct HighlightContext {
        let index: Int
        let text: String
        let cid: String
        let sentences: [(text: String, start: Int, end: Int)]
        let viewport: CGRect
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

    func cycleHighlightForTopVisibleParagraph(viewportWidth: CGFloat, scrollViewHeight: CGFloat, topFadeHeight: CGFloat) {
        guard let ctx = resolveHighlightContext(viewportWidth: viewportWidth, scrollViewHeight: scrollViewHeight, topFadeHeight: topFadeHeight) else { return }

        if let existing = autoHighlightIDs[ctx.index], !existing.isEmpty {
            highlightStore.removeBatch(ids: Set(existing))
        }

        let added = items[ctx.index].isWholeItemHighlightable
            ? wholeItemCycleHighlight(ctx: ctx)
            : sentenceCycleHighlights(ctx: ctx)

        if added.isEmpty {
            autoHighlightIDs[ctx.index] = []
        } else {
            highlightStore.addBatch(added)
            autoHighlightIDs[ctx.index] = added.map(\.id)
        }
    }

    func extendHighlightForTopVisibleParagraph(viewportWidth: CGFloat, scrollViewHeight: CGFloat, topFadeHeight: CGFloat) {
        guard let ctx = resolveHighlightContext(viewportWidth: viewportWidth, scrollViewHeight: scrollViewHeight, topFadeHeight: topFadeHeight) else { return }
        guard items[ctx.index].isHighlightableBody else {
            cycleHighlightForTopVisibleParagraph(viewportWidth: viewportWidth, scrollViewHeight: scrollViewHeight, topFadeHeight: topFadeHeight)
            return
        }
        guard !ctx.sentences.isEmpty else { return }

        let cycleStep = autoHighlightCycleStep[ctx.index] ?? 0
        guard lastPhaseWasSingleSentence(step: cycleStep, sentenceCount: ctx.sentences.count) else {
            cycleHighlightForTopVisibleParagraph(viewportWidth: viewportWidth, scrollViewHeight: scrollViewHeight, topFadeHeight: topFadeHeight)
            return
        }

        let cycleLength = cycleLengthFor(sentenceCount: ctx.sentences.count)
        let lastCyclePos = (cycleStep - 1) % cycleLength
        let startOffset = autoHighlightStartOffset[ctx.index] ?? 0
        let baseSentenceIdx = (startOffset + lastCyclePos) % ctx.sentences.count
        let currentExtend = autoHighlightExtendCount[ctx.index] ?? 0
        let maxExtend = ctx.sentences.count - 1 - baseSentenceIdx
        let newExtend = min(currentExtend + 1, maxExtend)
        guard newExtend > currentExtend else { return }
        autoHighlightExtendCount[ctx.index] = newExtend

        let startSentence = ctx.sentences[baseSentenceIdx]
        let endSentence = ctx.sentences[baseSentenceIdx + newExtend]
        let nsText = ctx.text as NSString
        let combinedRange = NSRange(location: startSentence.start, length: endSentence.end - startSentence.start)
        let combinedText = nsText.substring(with: combinedRange)

        if let existing = autoHighlightIDs[ctx.index], !existing.isEmpty {
            highlightStore.removeBatch(ids: Set(existing))
        }
        let h = Highlight(contentID: ctx.cid, text: combinedText, startOffset: startSentence.start, endOffset: endSentence.end)
        highlightStore.addBatch([h])
        autoHighlightIDs[ctx.index] = [h.id]
    }

    private func resolveHighlightContext(
        viewportWidth: CGFloat,
        scrollViewHeight: CGFloat,
        topFadeHeight: CGFloat
    ) -> HighlightContext? {
        let viewport = CGRect(
            x: 0,
            y: topFadeHeight,
            width: viewportWidth,
            height: max(0, scrollViewHeight * viewportHeightFraction - topFadeHeight)
        )
        guard let index = pickHighlightTarget(viewport: viewport) else { return nil }
        let text = textForAnalysis(items[index])
        guard !text.isEmpty else { return nil }
        let cid = contentIDForItem(at: index)
        let sentences = tokenizeSentences(in: text)
        return HighlightContext(index: index, text: text, cid: cid, sentences: sentences, viewport: viewport)
    }

    private func cycleLengthFor(sentenceCount: Int) -> Int {
        sentenceCount + (sentenceCount > 1 ? 2 : 1)
    }

    private func lastPhaseWasSingleSentence(step: Int, sentenceCount: Int) -> Bool {
        guard step > 0 else { return false }
        return (step - 1) % cycleLengthFor(sentenceCount: sentenceCount) < sentenceCount
    }

    private func pickHighlightTarget(viewport: CGRect) -> Int? {
        func frameIfEligible(_ index: Int) -> CGRect? {
            guard items.indices.contains(index),
                  items[index].isHighlightableBody || items[index].isWholeItemHighlightable,
                  let frame = paragraphFrames[index], frame.height > 0 else { return nil }
            return frame
        }
        if let newParagraph = visibleParagraphs.first(where: { index in
            guard let frame = frameIfEligible(index) else { return false }
            return frame.minY >= viewport.minY && frame.minY < viewport.maxY
        }) {
            return newParagraph
        }
        return visibleParagraphs.first { index in
            guard let frame = frameIfEligible(index) else { return false }
            return viewport.intersects(frame)
        }
    }

    private func sentenceCycleHighlights(ctx: HighlightContext) -> [Highlight] {
        guard !ctx.sentences.isEmpty else { return [] }

        let includeWholeParagraph = ctx.sentences.count > 1
        let cycleLength = cycleLengthFor(sentenceCount: ctx.sentences.count)
        let step = autoHighlightCycleStep[ctx.index] ?? 0
        let cyclePos = step % cycleLength

        let startOffset: Int
        if cyclePos == 0 {
            startOffset = startingSentenceIndex(itemIndex: ctx.index, viewport: ctx.viewport, sentences: ctx.sentences)
            autoHighlightStartOffset[ctx.index] = startOffset
        } else {
            startOffset = autoHighlightStartOffset[ctx.index] ?? 0
        }
        autoHighlightCycleStep[ctx.index] = step + 1
        autoHighlightExtendCount[ctx.index] = 0

        if cyclePos < ctx.sentences.count {
            let s = ctx.sentences[(startOffset + cyclePos) % ctx.sentences.count]
            return [Highlight(contentID: ctx.cid, text: s.text, startOffset: s.start, endOffset: s.end)]
        } else if includeWholeParagraph && cyclePos == ctx.sentences.count {
            return [Highlight(contentID: ctx.cid, text: ctx.text, startOffset: 0, endOffset: (ctx.text as NSString).length)]
        }
        return []
    }

    private func wholeItemCycleHighlight(ctx: HighlightContext) -> [Highlight] {
        let step = autoHighlightCycleStep[ctx.index] ?? 0
        autoHighlightCycleStep[ctx.index] = step + 1
        guard step % 2 == 0 else { return [] }
        return [Highlight(contentID: ctx.cid, text: ctx.text, startOffset: 0, endOffset: (ctx.text as NSString).length)]
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
        guard let frame = paragraphFrames[itemIndex], frame.height > 0 else { return 0 }
        if frame.minY >= viewport.minY { return 0 }

        let item = items[itemIndex]
        let paragraphWidth = viewport.width - 2 * horizontalPadding(for: item)
        guard paragraphWidth > 0 else { return 0 }

        let attributedText = attributedTextForItem(item)
        let textStorage = NSTextStorage(attributedString: attributedText)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: paragraphWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        _ = layoutManager.glyphRange(for: container)

        let effectiveTopInParagraph = viewport.minY - frame.minY

        for (idx, sentence) in sentences.enumerated() {
            let glyphIdx = layoutManager.glyphIndexForCharacter(at: sentence.start)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
            if lineRect.minY >= effectiveTopInParagraph {
                return idx
            }
        }
        return 0
    }
}

