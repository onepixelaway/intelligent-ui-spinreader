import SwiftUI
import NaturalLanguage

extension ScrollTextView {
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

    func cycleHighlightForTopVisibleParagraph(viewportWidth: CGFloat, scrollViewHeight: CGFloat) {
        let viewport = CGRect(x: 0, y: 0, width: viewportWidth, height: scrollViewHeight * viewportHeightFraction)
        let minVisibleFraction: CGFloat = 0.5

        let targetIndex = visibleParagraphs.first { index in
            guard items.indices.contains(index) else { return false }
            let item = items[index]
            guard item.isHighlightableBody || item.isWholeItemHighlightable else { return false }
            guard let frame = paragraphFrames[index], frame.height > 0 else { return false }
            let intersection = viewport.intersection(frame)
            return !intersection.isEmpty && intersection.height / frame.height >= minVisibleFraction
        }
        guard let index = targetIndex else { return }

        let text = textForAnalysis(items[index])
        guard !text.isEmpty else { return }
        let cid = contentIDForItem(at: index)

        if let existing = autoHighlightIDs[index], !existing.isEmpty {
            highlightStore.removeBatch(ids: Set(existing))
        }

        let added: [Highlight]
        if items[index].isWholeItemHighlightable {
            added = wholeItemCycleHighlight(text: text, cid: cid, itemIndex: index)
        } else {
            added = sentenceCycleHighlights(text: text, cid: cid, itemIndex: index)
        }

        if added.isEmpty {
            autoHighlightIDs[index] = []
        } else {
            highlightStore.addBatch(added)
            autoHighlightIDs[index] = added.map(\.id)
        }
    }

    private func sentenceCycleHighlights(text: String, cid: String, itemIndex: Int) -> [Highlight] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [(text: String, start: Int, end: Int)] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let raw = String(text[range])
            guard raw.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5 else { return true }
            let start = range.lowerBound.utf16Offset(in: text)
            let end = range.upperBound.utf16Offset(in: text)
            sentences.append((raw, start, end))
            return true
        }
        guard !sentences.isEmpty else { return [] }

        let includeWholeParagraph = sentences.count > 1
        let cycleLength = sentences.count + (includeWholeParagraph ? 2 : 1)
        let step = autoHighlightCycleStep[itemIndex] ?? 0
        let phase = step % cycleLength
        autoHighlightCycleStep[itemIndex] = step + 1

        if phase < sentences.count {
            let s = sentences[phase]
            return [Highlight(contentID: cid, text: s.text, startOffset: s.start, endOffset: s.end)]
        } else if includeWholeParagraph && phase == sentences.count {
            return [Highlight(contentID: cid, text: text, startOffset: 0, endOffset: (text as NSString).length)]
        }
        return []
    }

    // Two-phase cycle for items rendered via bespoke views: highlight whole item → deselect.
    private func wholeItemCycleHighlight(text: String, cid: String, itemIndex: Int) -> [Highlight] {
        let step = autoHighlightCycleStep[itemIndex] ?? 0
        autoHighlightCycleStep[itemIndex] = step + 1
        guard step % 2 == 0 else { return [] }
        return [Highlight(contentID: cid, text: text, startOffset: 0, endOffset: (text as NSString).length)]
    }
}
