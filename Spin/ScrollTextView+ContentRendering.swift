import SwiftUI

extension ScrollTextView {
    @ViewBuilder
    func readableItemView(_ item: ReadableItem, index: Int) -> some View {
        switch item {
        case .title(let text):
            highlightableBlock(text, attributedText: nsStyledText(text, size: readerSettings.titleSize, weight: .bold), itemIndex: index)
        case .byline(let text):
            highlightableBlock(text, attributedText: nsStyledText(text, size: readerSettings.bylineSize, weight: .semibold), itemIndex: index)
        case .paragraph(let text):
            highlightableBlock(text, attributedText: nsStyledText(text, size: readerSettings.paragraphSize, weight: .regular), itemIndex: index)
        case .richParagraph(let rt):
            highlightableBlock(rt.attributedString.string, attributedText: nsRichAttributedText(rt, size: readerSettings.paragraphSize), itemIndex: index)
        case .subheading(let text):
            highlightableBlock(text, attributedText: nsStyledText(text, size: readerSettings.titleSize - 4, weight: .bold), itemIndex: index)
        case .listItem(let text, let ordered, let listIdx):
            let prefix = ordered ? "\(listIdx). " : "\u{2022} "
            let fullText = prefix + text
            highlightableBlock(fullText, attributedText: nsStyledText(fullText, size: readerSettings.paragraphSize, weight: .regular), itemIndex: index, extraLeading: extraLeading(for: item))
        case .image(let url, let alt, let caption):
            ArticleImageView(url: url, alt: alt, caption: caption)
        case .blockquote(let text):
            wholeItemHighlight(text: text, itemIndex: index) {
                AccentedQuoteView(text: text)
            }
        case .code(let text):
            CodeBlockView(text: text)
        case .divider:
            Text("·  ·  ·")
                .font(.system(size: readerSettings.paragraphSize, weight: .regular, design: readerSettings.fontFamily.design))
                .foregroundColor(Color(white: 0.6, opacity: 0.6))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
        case .callout(let text):
            wholeItemHighlight(text: text, itemIndex: index) {
                AccentedQuoteView(text: text, barOpacity: 0.45, textWhite: 0.85, hasBackground: true)
            }
        case .paragraphWithFootnotes(let text, let footnotes):
            wholeItemHighlight(text: text, itemIndex: index) {
                FootnoteParagraphView(text: text, footnotes: footnotes, activeFootnote: $activeFootnote)
            }
        case .chapterTOC(let entries):
            ChapterTOCView(entries: entries)
        }
    }

    @ViewBuilder
    func wholeItemHighlight<Content: View>(
        text: String,
        itemIndex: Int,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let confirmedHighlights = highlightsForParagraph(text, itemIndex: itemIndex)
        let pendingHighlight = pendingHighlightForParagraph(text, itemIndex: itemIndex)
        if let pendingHighlight {
            let pendingColor = pendingHighlight.displayFillColor
            TimelineView(.animation) { timeline in
                content()
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(pendingColor.opacity(pendingHighlightOpacity(at: timeline.date)))
                            .padding(.horizontal, -6)
                            .padding(.vertical, -4)
                    )
            }
        } else {
            let confirmedColor = confirmedHighlights.first?.displayFillColor ?? .yellow
            content()
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(confirmedColor.opacity(confirmedHighlights.isEmpty ? 0 : 0.25))
                        .padding(.horizontal, -6)
                        .padding(.vertical, -4)
                )
        }
    }

    func horizontalPadding(for item: ReadableItem) -> CGFloat {
        let base = readerSettings.margins.horizontalPadding
        return item.usesWideHorizontalPadding ? max(8, base - 12) : base
    }

    // Indent applied at render time inside the item's horizontal padding (e.g. list-item bullets).
    // Pagination must subtract this from the measurement width so wrapped line counts match what
    // HighlightableTextView actually renders.
    func extraLeading(for item: ReadableItem) -> CGFloat {
        switch item {
        case .listItem:
            return 16
        case .title, .byline, .paragraph, .richParagraph, .subheading, .image, .blockquote, .code, .divider, .callout, .paragraphWithFootnotes, .chapterTOC:
            return 0
        }
    }

    @ViewBuilder
    func highlightableBlock(_ text: String, attributedText: NSAttributedString, itemIndex: Int, extraLeading: CGFloat = 0) -> some View {
        let matching = highlightsForParagraph(text, itemIndex: itemIndex)
        let cid = contentIDForItem(at: itemIndex)
        let pendingHighlight = pendingHighlightForParagraph(text, itemIndex: itemIndex)
        let onCreated: (String, Int, Int) -> Void = { selectedText, start, end in
            highlightStore.add(Highlight(
                contentID: cid,
                text: selectedText,
                startOffset: start,
                endOffset: end,
                color: selectedHighlightColor.rawValue,
                emoji: selectedHighlightEmoji?.rawValue
            ))
        }
        let onRemoved: (UUID) -> Void = { id in
            highlightStore.remove(id: id)
        }
        let onSettingsEmptyTap: () -> Void = { toggleSettingsMode() }
        Group {
            if pendingHighlight != nil {
                TimelineView(.animation) { timeline in
                    HighlightableTextView(
                        text: text,
                        attributedText: attributedText,
                        itemIndex: itemIndex,
                        highlights: matching,
                        playbackHighlight: speechCoordinator.highlight,
                        isPlaybackActive: speechCoordinator.isPlaybackActive,
                        pendingHighlight: pendingHighlight,
                        pendingOpacity: pendingHighlightOpacity(at: timeline.date),
                        showsPendingCursor: pendingHighlightCursorVisible(at: timeline.date),
                        onHighlightCreated: onCreated,
                        onHighlightRemoved: onRemoved,
                        onPlaybackWordTapped: { offset in
                            startPlayback(
                                at: PlaybackTextLocation(itemIndex: itemIndex, offset: offset)
                            )
                        },
                        onEmptyTap: onSettingsEmptyTap
                    )
                }
            } else {
                HighlightableTextView(
                    text: text,
                    attributedText: attributedText,
                    itemIndex: itemIndex,
                    highlights: matching,
                    playbackHighlight: speechCoordinator.highlight,
                    isPlaybackActive: speechCoordinator.isPlaybackActive,
                    pendingHighlight: nil,
                    pendingOpacity: 0.25,
                    showsPendingCursor: false,
                    onHighlightCreated: onCreated,
                    onHighlightRemoved: onRemoved,
                    onPlaybackWordTapped: { offset in
                        startPlayback(
                            at: PlaybackTextLocation(itemIndex: itemIndex, offset: offset)
                        )
                    },
                    onEmptyTap: onSettingsEmptyTap
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, extraLeading)
    }

    private func pendingHighlightOpacity(at date: Date) -> CGFloat {
        let phase = (sin(date.timeIntervalSinceReferenceDate * 2.0 * Double.pi / 1.4) + 1.0) / 2.0
        return 0.16 + CGFloat(phase) * 0.12
    }

    private func pendingHighlightCursorVisible(at date: Date) -> Bool {
        Int(date.timeIntervalSinceReferenceDate * 2.0) % 2 == 0
    }
}
