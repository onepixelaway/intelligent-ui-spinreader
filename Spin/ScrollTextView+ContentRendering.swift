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
            highlightableBlock(fullText, attributedText: nsStyledText(fullText, size: readerSettings.paragraphSize, weight: .regular), itemIndex: index, extraLeading: 16)
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
        let isHighlighted = !highlightsForParagraph(text, itemIndex: itemIndex).isEmpty
        let pendingHighlight = pendingHighlightForParagraph(text, itemIndex: itemIndex)
        TimelineView(.animation) { timeline in
            let pendingOpacity = pendingHighlightOpacity(at: timeline.date)
            let pendingColor = pendingHighlight.flatMap { HighlightColorChoice(rawValue: $0.color)?.fillColor } ?? .clear
            content()
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            pendingHighlight == nil
                            ? Color.yellow.opacity(isHighlighted ? 0.25 : 0)
                            : pendingColor.opacity(pendingOpacity)
                        )
                        .padding(.horizontal, -6)
                        .padding(.vertical, -4)
                )
        }
    }

    func horizontalPadding(for item: ReadableItem) -> CGFloat {
        let base = readerSettings.margins.horizontalPadding
        return item.usesWideHorizontalPadding ? max(8, base - 12) : base
    }

    @ViewBuilder
    func highlightableBlock(_ text: String, attributedText: NSAttributedString, itemIndex: Int, extraLeading: CGFloat = 0) -> some View {
        let matching = highlightsForParagraph(text, itemIndex: itemIndex)
        let cid = contentIDForItem(at: itemIndex)
        let pendingHighlight = pendingHighlightForParagraph(text, itemIndex: itemIndex)
        TimelineView(.animation) { timeline in
            HighlightableTextView(
                text: text,
                attributedText: attributedText,
                highlights: matching,
                pendingHighlight: pendingHighlight,
                pendingOpacity: pendingHighlightOpacity(at: timeline.date),
                showsPendingCursor: pendingHighlight != nil && pendingHighlightCursorVisible(at: timeline.date),
                onHighlightCreated: { selectedText, start, end in
                    highlightStore.add(Highlight(contentID: cid, text: selectedText, startOffset: start, endOffset: end))
                },
                onHighlightRemoved: { id in
                    highlightStore.remove(id: id)
                }
            )
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
