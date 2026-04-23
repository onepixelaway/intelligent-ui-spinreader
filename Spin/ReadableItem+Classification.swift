import SwiftUI

extension ScrollTextView.ReadableItem {
    var usesWideHorizontalPadding: Bool {
        switch self {
        case .image, .code:
            return true
        case .title, .byline, .paragraph, .richParagraph, .subheading, .listItem, .blockquote, .divider, .callout, .paragraphWithFootnotes, .chapterTOC:
            return false
        }
    }

    // Item types rendered via `highlightableBlock` — support per-sentence highlight cycling. Keep in sync with `readableItemView`.
    var isHighlightableBody: Bool {
        switch self {
        case .paragraph, .richParagraph, .listItem:
            return true
        case .title, .byline, .subheading, .blockquote, .callout, .paragraphWithFootnotes, .image, .code, .divider, .chapterTOC:
            return false
        }
    }

    // Item types rendered via bespoke views (blockquote bar, footnote links). Support a simpler whole-item highlight toggle to preserve their styling.
    var isWholeItemHighlightable: Bool {
        switch self {
        case .blockquote, .callout, .paragraphWithFootnotes:
            return true
        case .paragraph, .richParagraph, .listItem, .title, .byline, .subheading, .image, .code, .divider, .chapterTOC:
            return false
        }
    }

    // Items that render via `HighlightableTextView` (UIKit UITextView). Their internal line
    // fragments can be measured with TextKit and pagination may break between any two lines.
    // Everything else is atomic: it either fits on a page or moves whole to the next.
    var isSplittable: Bool {
        switch self {
        case .title, .byline, .paragraph, .richParagraph, .subheading, .listItem:
            return true
        case .image, .blockquote, .code, .divider, .callout, .paragraphWithFootnotes, .chapterTOC:
            return false
        }
    }
}
