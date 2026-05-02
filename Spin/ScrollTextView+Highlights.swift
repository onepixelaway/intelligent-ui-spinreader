import SwiftUI
import UIKit
import NaturalLanguage
import CoreText

extension ScrollTextView {
    struct AutoHighlightSelection {
        let itemIndex: Int
        let sentenceRange: ClosedRange<Int>?
        var highlight: Highlight
    }

    enum AutoHighlightUpdate {
        case none
        case changed(targetPage: Int?)
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
        let targetPage: Int?
    }

    private enum HighlightNavigationDirection {
        case none
        case previous
        case next
    }

    private struct TextLayoutContext {
        let layoutManager: NSLayoutManager
        let textContainer: NSTextContainer
        let attributedText: NSAttributedString
        let textWidth: CGFloat
        let frame: CGRect
    }

    func contentIDForItem(at index: Int) -> String {
        guard itemContentIDs.indices.contains(index) else { return contentID }
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
        topFadeHeight: CGFloat,
        scrollOffset: CGFloat
    ) -> AutoHighlightUpdate {
        let viewport = highlightViewport(
            viewportWidth: viewportWidth,
            scrollViewHeight: scrollViewHeight,
            topFadeHeight: topFadeHeight,
            scrollOffset: scrollOffset
        )
        guard viewport.width > 0, viewport.height > 0 else { return .none }

        let target = nextAutoHighlightTarget(viewport: viewport)

        guard let target else { return .none }
        autoHighlightSelection = target.selection
        return .changed(targetPage: target.targetPage)
    }

    func previousHighlightForTopVisibleParagraph(
        viewportWidth: CGFloat,
        scrollViewHeight: CGFloat,
        topFadeHeight: CGFloat,
        scrollOffset: CGFloat
    ) -> AutoHighlightUpdate {
        let viewport = highlightViewport(
            viewportWidth: viewportWidth,
            scrollViewHeight: scrollViewHeight,
            topFadeHeight: topFadeHeight,
            scrollOffset: scrollOffset
        )
        guard viewport.width > 0, viewport.height > 0 else { return .none }

        guard let target = previousAutoHighlightTarget(viewport: viewport) else { return .none }
        autoHighlightSelection = target.selection
        return .changed(targetPage: target.targetPage)
    }

    func updatePendingHighlightColor(_ color: HighlightColorChoice) {
        guard var selection = autoHighlightSelection else { return }
        selection.highlight.color = color.rawValue
        selection.highlight.emoji = nil
        autoHighlightSelection = selection
    }

    func updatePendingHighlightEmoji(_ emoji: HighlightEmojiChoice) {
        guard var selection = autoHighlightSelection else { return }
        selection.highlight.emoji = emoji.rawValue
        autoHighlightSelection = selection
    }

    func confirmPendingHighlight() {
        guard let selection = autoHighlightSelection else { return }
        highlightStore.add(selection.highlight)
        autoHighlightSelection = nil
    }

    func cancelPendingHighlight() {
        autoHighlightSelection = nil
    }

    func pendingHighlightForParagraph(_ text: String, itemIndex: Int) -> Highlight? {
        guard let selection = autoHighlightSelection,
              selection.itemIndex == itemIndex else { return nil }
        let highlight = selection.highlight
        let nsText = text as NSString
        guard highlight.startOffset >= 0,
              highlight.endOffset <= nsText.length,
              highlight.startOffset < highlight.endOffset,
              nsText.substring(with: NSRange(location: highlight.startOffset, length: highlight.endOffset - highlight.startOffset)) == highlight.text else {
            return nil
        }
        return highlight
    }

    private var currentHighlightColorRaw: String {
        selectedHighlightColor.rawValue
    }

    private var currentHighlightEmojiRaw: String? {
        selectedHighlightEmoji?.rawValue
    }

    private func highlightViewport(
        viewportWidth: CGFloat,
        scrollViewHeight: CGFloat,
        topFadeHeight: CGFloat,
        scrollOffset: CGFloat
    ) -> CGRect {
        CGRect(
            x: 0,
            y: topFadeHeight - scrollOffset,
            width: viewportWidth,
            height: max(0, scrollViewHeight - topFadeHeight)
        )
    }

    private func contentFrame(for itemIndex: Int) -> CGRect? {
        if let frame = lastPaginationFrames[itemIndex] {
            return frame
        }
        return paragraphFrames[itemIndex]
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
        let eligibleFrames = items.indices
            .compactMap { index -> (index: Int, frame: CGRect)? in
                guard items.indices.contains(index),
                      items[index].isHighlightableBody || items[index].isWholeItemHighlightable,
                      let frame = contentFrame(for: index),
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
            return wholeItemHighlightTarget(ctx: ctx, viewport: viewport, direction: .none)
        }
        guard !ctx.sentences.isEmpty else { return nil }
        let sentenceIndex = startingSentenceIndex(itemIndex: ctx.index, viewport: viewport, sentences: ctx.sentences)
        return sentenceHighlightTarget(
            ctx: ctx,
            sentenceRange: sentenceIndex...sentenceIndex,
            viewport: viewport,
            direction: .none
        )
    }

    private func nextAutoHighlightTarget(viewport: CGRect) -> HighlightTarget? {
        if let selection = autoHighlightSelection, shouldContinueAutoHighlight(selection, viewport: viewport) {
            return nextHighlightTarget(after: selection, viewport: viewport)
        }
        return startingHighlightTarget(viewport: viewport)
    }

    private func previousAutoHighlightTarget(viewport: CGRect) -> HighlightTarget? {
        if let selection = autoHighlightSelection, shouldContinueAutoHighlight(selection, viewport: viewport) {
            return previousHighlightTarget(before: selection, viewport: viewport)
        }
        return startingHighlightTarget(viewport: viewport)
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
                    viewport: viewport,
                    direction: .next
                )
            }
        }

        return nextHighlightTarget(afterItemIndex: selection.itemIndex, viewport: viewport)
    }

    private func previousHighlightTarget(before selection: AutoHighlightSelection, viewport: CGRect) -> HighlightTarget? {
        guard items.indices.contains(selection.itemIndex) else { return nil }

        if items[selection.itemIndex].isHighlightableBody,
           let sentenceRange = selection.sentenceRange,
           let ctx = resolveHighlightContext(for: selection.itemIndex, viewport: viewport) {
            let previousSentenceIndex = sentenceRange.lowerBound - 1
            if previousSentenceIndex >= 0 {
                return sentenceHighlightTarget(
                    ctx: ctx,
                    sentenceRange: previousSentenceIndex...previousSentenceIndex,
                    viewport: viewport,
                    direction: .previous
                )
            }
        }

        return previousHighlightTarget(beforeItemIndex: selection.itemIndex, viewport: viewport)
    }

    private func previousHighlightTarget(beforeItemIndex itemIndex: Int, viewport: CGRect) -> HighlightTarget? {
        for previousIndex in items.indices.reversed() where previousIndex < itemIndex {
            guard let ctx = resolveHighlightContext(for: previousIndex, viewport: viewport) else { continue }
            if items[previousIndex].isWholeItemHighlightable {
                return wholeItemHighlightTarget(ctx: ctx, viewport: viewport, direction: .previous)
            }
            if let lastSentenceIndex = ctx.sentences.indices.last {
                return sentenceHighlightTarget(
                    ctx: ctx,
                    sentenceRange: lastSentenceIndex...lastSentenceIndex,
                    viewport: viewport,
                    direction: .previous
                )
            }
        }
        return nil
    }

    private func nextHighlightTarget(afterItemIndex itemIndex: Int, viewport: CGRect) -> HighlightTarget? {
        for nextIndex in items.indices where nextIndex > itemIndex {
            guard let ctx = resolveHighlightContext(for: nextIndex, viewport: viewport) else { continue }
            if items[nextIndex].isWholeItemHighlightable {
                return wholeItemHighlightTarget(ctx: ctx, viewport: viewport, direction: .next)
            }
            if !ctx.sentences.isEmpty {
                return sentenceHighlightTarget(
                    ctx: ctx,
                    sentenceRange: 0...0,
                    viewport: viewport,
                    direction: .next
                )
            }
        }
        return nil
    }

    private func sentenceHighlightTarget(
        ctx: HighlightContext,
        sentenceRange: ClosedRange<Int>,
        viewport: CGRect,
        direction: HighlightNavigationDirection
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
            endOffset: endSentence.end,
            color: currentHighlightColorRaw,
            emoji: currentHighlightEmojiRaw
        )
        // Use the paginator-aligned y first. The fallbacks keep older whole-item behavior working,
        // but they are not precise enough to decide split-paragraph page flips.
        let startYForPaging = pagingStartYForHighlight(
            for: combinedRange,
            itemIndex: ctx.index,
            text: nsText
        ) ?? highlightRect(for: sentenceRange, in: ctx)?.minY ?? contentFrame(for: ctx.index)?.minY
        let targetPage = targetPageForHighlightStart(
            at: startYForPaging,
            direction: direction
        )
        return HighlightTarget(
            selection: AutoHighlightSelection(
                itemIndex: ctx.index,
                sentenceRange: sentenceRange,
                highlight: highlight
            ),
            targetPage: targetPage
        )
    }

    private func wholeItemHighlightTarget(
        ctx: HighlightContext,
        viewport: CGRect,
        direction: HighlightNavigationDirection
    ) -> HighlightTarget? {
        let endOffset = (ctx.text as NSString).length
        guard endOffset > 0 else { return nil }
        let highlight = Highlight(
            contentID: ctx.cid,
            text: ctx.text,
            startOffset: 0,
            endOffset: endOffset,
            color: currentHighlightColorRaw,
            emoji: currentHighlightEmojiRaw
        )
        let targetPage = targetPageForHighlightStart(at: contentFrame(for: ctx.index)?.minY, direction: direction)
        return HighlightTarget(
            selection: AutoHighlightSelection(itemIndex: ctx.index, sentenceRange: nil, highlight: highlight),
            targetPage: targetPage
        )
    }

    // Highlight cycling flips pages only when the selected highlight starts on another
    // page, never just because it is below the smaller highlight-mode panel viewport.
    // For sentence highlights, `startY` must come from paginationAlignedLineMinY so it
    // uses the same line measurements as pageStarts; fresh layout measurements can drift
    // by a fraction of a point and miss split-paragraph page boundaries.
    private func targetPageForHighlightStart(
        at startY: CGFloat?,
        direction: HighlightNavigationDirection
    ) -> Int? {
        guard let startY else { return nil }

        switch direction {
        case .none:
            return nil
        case .previous:
            return scrollState.pageChangeForContentStart(at: Double(startY), movingForward: false)
        case .next:
            return scrollState.pageChangeForContentStart(at: Double(startY), movingForward: true)
        }
    }

    // Content-space y for the first non-whitespace character, aligned with pageStarts.
    private func pagingStartYForHighlight(
        for range: NSRange,
        itemIndex: Int,
        text: NSString
    ) -> CGFloat? {
        guard range.location >= 0,
              range.length > 0,
              NSMaxRange(range) <= text.length else { return nil }

        let firstText = text.rangeOfCharacter(
            from: CharacterSet.whitespacesAndNewlines.inverted,
            options: [],
            range: range
        )
        let start = firstText.location == NSNotFound ? range.location : firstText.location
        guard start < NSMaxRange(range) else { return nil }

        return paginationAlignedLineMinY(containingCharacterAt: start, itemIndex: itemIndex)
    }

    // MUST use paginationAttributedText + paginationTextWidth + Paginator.measureLines —
    // the same pipeline used by recomputePageStarts(). Do not replace this with
    // textLayoutContext or render-time widths; tiny y drift breaks mid-paragraph page flips.
    private func paginationAlignedLineMinY(containingCharacterAt characterIndex: Int, itemIndex: Int) -> CGFloat? {
        guard items.indices.contains(itemIndex),
              let frame = contentFrame(for: itemIndex),
              frame.height > 0,
              lastPaginationViewportWidth > 0 else { return nil }
        let item = items[itemIndex]
        guard let attributed = paginationAttributedText(for: item) else { return nil }
        guard characterIndex >= 0, characterIndex < attributed.length else { return nil }

        let width = paginationTextWidth(for: item, viewportWidth: lastPaginationViewportWidth)
        let lines = Paginator.measureLines(for: attributed, width: width)
        guard !lines.isEmpty else { return nil }

        // Measure how many lines the prefix [0..<characterIndex+1] produces;
        // the last line of that prefix is the line containing the character.
        let prefixLength = min(characterIndex + 1, attributed.length)
        let prefixLines = Paginator.measureLines(
            for: attributed.attributedSubstring(from: NSRange(location: 0, length: prefixLength)),
            width: width
        )
        let lineIndex = max(0, min(prefixLines.count - 1, lines.count - 1))
        let line = lines[lineIndex]

        return frame.minY + CGFloat(line.minY)
    }

    private func textLayoutContext(for itemIndex: Int, viewport: CGRect) -> TextLayoutContext? {
        guard items.indices.contains(itemIndex),
              let frame = contentFrame(for: itemIndex),
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

        return TextLayoutContext(
            layoutManager: layoutManager,
            textContainer: container,
            attributedText: attributedText,
            textWidth: paragraphWidth,
            frame: frame
        )
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

    func firstVisibleCharacterIndex(itemIndex: Int, viewport: CGRect, text: String) -> Int? {
        guard let frame = contentFrame(for: itemIndex),
              let layout = textLayoutContext(for: itemIndex, viewport: viewport) else { return nil }

        let visibleTop = max(0, viewport.minY - frame.minY)
        let visibleBottom = min(frame.height, max(visibleTop + 1, viewport.maxY - frame.minY))
        guard visibleBottom > visibleTop else { return nil }
        let nsText = text as NSString
        guard nsText.length > 0 else { return nil }

        let fullGlyphRange = layout.layoutManager.glyphRange(for: layout.textContainer)
        guard fullGlyphRange.length > 0 else { return nil }

        var firstVisibleRange: NSRange?
        layout.layoutManager.enumerateLineFragments(forGlyphRange: fullGlyphRange) { lineRect, _, _, glyphRange, stop in
            guard lineRect.maxY > visibleTop + 0.5,
                  lineRect.minY < visibleBottom - 0.5 else { return }
            firstVisibleRange = layout.layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            stop.pointee = true
        }

        guard let rawRange = firstVisibleRange else { return nil }
        let start = min(max(0, rawRange.location), max(0, nsText.length - 1))
        let end = min(NSMaxRange(rawRange), nsText.length)
        guard end > start else { return start }

        let lineRange = NSRange(location: start, length: end - start)
        let firstNonWhitespace = nsText.rangeOfCharacter(
            from: CharacterSet.whitespacesAndNewlines.inverted,
            options: [],
            range: lineRange
        )
        if firstNonWhitespace.location != NSNotFound {
            return firstNonWhitespace.location
        }
        return lineRange.location
    }

    func tokenizeSentences(in text: String, minTrimmedLength: Int = 5) -> [(text: String, start: Int, end: Int)] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [(text: String, start: Int, end: Int)] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let raw = String(text[range])
            guard raw.trimmingCharacters(in: .whitespacesAndNewlines).count >= minTrimmedLength else { return true }
            let start = range.lowerBound.utf16Offset(in: text)
            let end = range.upperBound.utf16Offset(in: text)
            result.append((raw, start, end))
            return true
        }
        return result
    }

    func firstVisiblePlaybackLocation(viewport: CGRect) -> PlaybackTextLocation? {
        let candidates = items.indices
            .compactMap { index -> (index: Int, frame: CGRect)? in
                guard renderedAttributedText(for: items[index]) != nil,
                      let frame = contentFrame(for: index),
                      frame.height > 0,
                      viewport.intersects(frame) else { return nil }
                return (index, frame)
            }
            .sorted {
                if abs($0.frame.minY - $1.frame.minY) > 0.5 {
                    return $0.frame.minY < $1.frame.minY
                }
                return $0.index < $1.index
            }

        for candidate in candidates {
            guard let text = renderedAttributedText(for: items[candidate.index])?.string else { continue }
            // Items that start at or below the viewport top are read from the first word.
            // Items that extend above the viewport need a per-line lookup; skip the candidate
            // if visibility detection fails so we don't read text that is offscreen.
            let visibleOffset: Int
            if candidate.frame.minY >= viewport.minY - 0.5 {
                visibleOffset = 0
            } else if let computed = firstVisibleCharacterIndex(
                itemIndex: candidate.index,
                viewport: viewport,
                text: text
            ) {
                visibleOffset = computed
            } else {
                continue
            }
            if let wordRange = wordRange(atOrAfter: visibleOffset, in: text) {
                return PlaybackTextLocation(itemIndex: candidate.index, offset: wordRange.location)
            }
        }

        return nil
    }

    func playbackSegments(startingAt location: PlaybackTextLocation?) -> [PlaybackTextSegment] {
        guard let location,
              items.indices.contains(location.itemIndex) else { return [] }

        var segments: [PlaybackTextSegment] = []
        for itemIndex in items.indices where itemIndex >= location.itemIndex {
            guard let text = renderedAttributedText(for: items[itemIndex])?.string else { continue }
            let nsText = text as NSString
            guard nsText.length > 0 else { continue }

            let requestedOffset = itemIndex == location.itemIndex ? location.offset : 0
            guard let firstWord = wordRange(atOrAfter: requestedOffset, in: text) else { continue }
            // Use unfiltered sentences so that a short sentence at the visible top
            // ("OK.", "Hi.", a fragment) isn't skipped before TTS reaches the next sentence.
            let sentences = tokenizeSentences(in: text, minTrimmedLength: 0)
            let sentenceRanges: [NSRange] = sentences.isEmpty
                ? [NSRange(location: 0, length: nsText.length)]
                : sentences.map { NSRange(location: $0.start, length: $0.end - $0.start) }

            for sentenceRange in sentenceRanges {
                let sentenceEnd = NSMaxRange(sentenceRange)
                guard sentenceEnd > firstWord.location else { continue }
                let utteranceStart = max(sentenceRange.location, firstWord.location)
                guard utteranceStart < sentenceEnd else { continue }
                let rawUtteranceRange = NSRange(location: utteranceStart, length: sentenceEnd - utteranceStart)
                let rawUtterance = nsText.substring(with: rawUtteranceRange)
                let leadingOffset = (rawUtterance as NSString)
                    .rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted)
                    .location
                let adjustedStart = leadingOffset == NSNotFound
                    ? utteranceStart
                    : utteranceStart + leadingOffset
                let adjustedRange = NSRange(location: adjustedStart, length: sentenceEnd - adjustedStart)
                let utteranceText = nsText.substring(with: adjustedRange)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !utteranceText.isEmpty else { continue }

                segments.append(PlaybackTextSegment(
                    itemIndex: itemIndex,
                    sentenceRange: sentenceRange,
                    utteranceStartOffset: adjustedStart,
                    utteranceText: utteranceText
                ))
            }
        }

        return segments
    }

    /// Content-space rect of the currently spoken word (or sentence, before the first
    /// word fires). The reader uses this to detect when the highlight has moved past the
    /// visible page bottom — same off-screen check the manual highlight cycle uses —
    /// and flip to the page that contains it.
    func playbackHighlightContentRect(_ highlight: PlaybackTextHighlight, viewport: CGRect) -> CGRect? {
        guard viewport.width > 0, viewport.height > 0 else { return nil }
        let range = highlight.wordRange ?? highlight.sentenceRange
        return textRect(for: range, itemIndex: highlight.itemIndex, viewport: viewport)
    }

    func playbackHighlightTargetPage(_ highlight: PlaybackTextHighlight, viewport: CGRect) -> Int? {
        guard let range = highlight.wordRange,
              items.indices.contains(highlight.itemIndex),
              let attributedText = renderedAttributedText(for: items[highlight.itemIndex]),
              attributedText.length > 0,
              let frame = contentFrame(for: highlight.itemIndex) else { return nil }

        let textWidth = viewport.width - 2 * horizontalPadding(for: items[highlight.itemIndex])
        let lines = Paginator.measureLines(for: attributedText, width: Double(textWidth))
        guard !lines.isEmpty else { return nil }

        let progress = Double(min(NSMaxRange(range), attributedText.length)) / Double(attributedText.length)
        let lineIndex = min(
            lines.count - 1,
            max(0, Int((progress * Double(lines.count)).rounded(.down)))
        )
        let lineY = frame.minY + CGFloat(lines[lineIndex].minY)
        let targetPage = scrollState.pageContaining(y: Double(lineY) + 0.5)
        guard targetPage > scrollState.currentPage else { return nil }
        return targetPage
    }

    private func textRect(for range: NSRange, itemIndex: Int, viewport: CGRect) -> CGRect? {
        guard let layout = textLayoutContext(for: itemIndex, viewport: viewport),
              let textLength = layout.layoutManager.textStorage?.length,
              range.location >= 0,
              range.length > 0,
              NSMaxRange(range) <= textLength else { return nil }

        if let coreTextRect = coreTextLineRect(
            for: range,
            attributedText: layout.attributedText,
            width: layout.textWidth,
            itemFrame: layout.frame
        ) {
            return coreTextRect
        }

        let fullGlyphRange = layout.layoutManager.glyphRange(for: layout.textContainer)
        var rect = CGRect.null
        layout.layoutManager.enumerateLineFragments(forGlyphRange: fullGlyphRange) { lineRect, _, _, glyphRange, _ in
            let characterRange = layout.layoutManager.characterRange(
                forGlyphRange: glyphRange,
                actualGlyphRange: nil
            )
            guard NSIntersectionRange(characterRange, range).length > 0 else { return }
            rect = rect.union(lineRect)
        }
        if rect.isNull || rect.isEmpty {
            let glyphRange = layout.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
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

    private func coreTextLineRect(
        for range: NSRange,
        attributedText: NSAttributedString,
        width: CGFloat,
        itemFrame: CGRect
    ) -> CGRect? {
        guard width > 0, attributedText.length > 0 else { return nil }

        let measuredLines = Paginator.measureLines(for: attributedText, width: Double(width))
        guard !measuredLines.isEmpty else { return nil }
        let prefixLength = min(NSMaxRange(range), attributedText.length)
        let prefix = attributedText.attributedSubstring(from: NSRange(location: 0, length: prefixLength))
        let prefixLineCount = Paginator.measureLines(for: prefix, width: Double(width)).count
        let lineIndex: Int
        if prefixLineCount > 1 || measuredLines.count <= 1 {
            lineIndex = max(0, prefixLineCount - 1)
        } else {
            let progress = Double(prefixLength) / Double(max(1, attributedText.length))
            lineIndex = min(
                measuredLines.count - 1,
                max(0, Int((progress * Double(measuredLines.count)).rounded(.down)))
            )
        }
        if measuredLines.indices.contains(lineIndex) {
            let fragment = measuredLines[lineIndex]
            return CGRect(
                x: itemFrame.minX,
                y: itemFrame.minY + CGFloat(fragment.minY),
                width: width,
                height: CGFloat(fragment.maxY - fragment.minY)
            )
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributedText)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: attributedText.length),
            nil,
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            nil
        )
        let frameHeight = max(1, ceil(suggested.height) + 16)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: frameHeight), transform: nil)
        let textFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributedText.length),
            path,
            nil
        )
        let lines = CTFrameGetLines(textFrame) as NSArray as? [CTLine] ?? []
        guard !lines.isEmpty else { return nil }

        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(textFrame, CFRange(location: 0, length: lines.count), &origins)

        var rect = CGRect.null
        for (index, line) in lines.enumerated() {
            guard measuredLines.indices.contains(index) else { continue }
            let cfRange = CTLineGetStringRange(line)
            let lineRange = NSRange(location: cfRange.location, length: cfRange.length)
            guard NSIntersectionRange(lineRange, range).length > 0 else { continue }

            let fragment = measuredLines[index]
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            rect = rect.union(CGRect(
                x: itemFrame.minX,
                y: itemFrame.minY + CGFloat(fragment.minY),
                width: lineWidth,
                height: CGFloat(fragment.maxY - fragment.minY)
            ))
        }

        guard !rect.isNull, !rect.isEmpty else { return nil }
        return rect
    }

    private func wordRange(atOrAfter offset: Int, in text: String) -> NSRange? {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var result: NSRange?
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let start = range.lowerBound.utf16Offset(in: text)
            let end = range.upperBound.utf16Offset(in: text)
            let tokenRange = NSRange(location: start, length: end - start)
            if NSMaxRange(tokenRange) > offset {
                result = tokenRange
                return false
            }
            return true
        }
        return result
    }

    #if DEBUG
    func debugSimulatePlaybackWordOnNextPage() {
        let viewport = CGRect(
            x: 0,
            y: -CGFloat(scrollState.offset),
            width: CGFloat(lastPaginationViewportWidth),
            height: CGFloat(lastPaginationViewportHeight)
        )
        guard viewport.width > 0, viewport.height > 0 else {
            debugPlaybackPagingStatus = "simulate bad viewport"
            return
        }
        debugPlaybackPagingStatus = "scan pages \(scrollState.totalPages)"
        var maxWordPage = scrollState.currentPage
        var maxWordY: CGFloat = 0
        var debugLineCount = 0
        var debugTextWidth: CGFloat = 0
        var maxLinePage = scrollState.currentPage
        var maxLineY: CGFloat = 0

        for itemIndex in items.indices {
            guard let attributed = renderedAttributedText(for: items[itemIndex]) else { continue }
            let textWidth = viewport.width - 2 * horizontalPadding(for: items[itemIndex])
            let measuredLines = Paginator.measureLines(for: attributed, width: Double(textWidth))
            if measuredLines.count > debugLineCount {
                debugLineCount = measuredLines.count
                debugTextWidth = textWidth
            }

            for (lineIndex, line) in measuredLines.enumerated() {
                let lineY = (contentFrame(for: itemIndex)?.minY ?? 0) + CGFloat(line.minY)
                let linePage = scrollState.pageContaining(y: Double(lineY) + 0.5)
                maxLineY = max(maxLineY, lineY)
                maxLinePage = max(maxLinePage, linePage)
                guard linePage > scrollState.currentPage else { continue }
                guard let location = characterLocation(
                    forLineIndex: lineIndex,
                    attributedText: attributed,
                    width: textWidth
                ) else { continue }
                let wordRange = NSRange(location: location, length: 1)
                maxWordPage = max(maxWordPage, linePage)
                maxWordY = max(maxWordY, lineY)
                debugPlaybackPagingStatus = "selected item \(itemIndex) loc \(location) linePage \(linePage)"
                speechCoordinator.debugSetPlaybackHighlight(PlaybackTextHighlight(
                    itemIndex: itemIndex,
                    sentenceRange: wordRange,
                    wordRange: wordRange
                ))
                return
            }
        }
        debugPlaybackPagingStatus = "no next-page word pages \(scrollState.totalPages) max \(maxWordPage) y \(Int(maxWordY)) lineMax \(maxLinePage) ly \(Int(maxLineY)) lines \(debugLineCount) w \(Int(debugTextWidth))"
    }

    private func characterLocation(
        forLineIndex targetLineIndex: Int,
        attributedText: NSAttributedString,
        width: CGFloat
    ) -> Int? {
        guard attributedText.length > 0 else { return nil }
        let measuredLines = Paginator.measureLines(for: attributedText, width: Double(width))
        guard measuredLines.count > 1 else { return nil }
        let progress = Double(targetLineIndex) / Double(max(1, measuredLines.count - 1))
        return min(
            attributedText.length - 1,
            max(0, Int((progress * Double(attributedText.length - 1)).rounded(.down)))
        )
    }
    #endif

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

        guard let frame = contentFrame(for: itemIndex), frame.height > 0 else { return 0 }
        if frame.minY >= viewport.minY {
            return 0
        }

        if let layout = textLayoutContext(for: itemIndex, viewport: viewport) {
            let effectiveTopInParagraph = viewport.minY - frame.minY
            for (idx, sentence) in sentences.enumerated() {
                let glyphIdx = layout.layoutManager.glyphIndexForCharacter(at: sentence.start)
                let lineRect = layout.layoutManager.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
                if lineRect.maxY > effectiveTopInParagraph {
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
