import SwiftUI
import UIKit

extension ScrollTextView {
    func attributedTextForItem(_ item: ReadableItem) -> NSAttributedString {
        switch item {
        case .paragraph(let text):
            return nsStyledText(text, size: readerSettings.paragraphSize, weight: .regular)
        case .richParagraph(let rt):
            return nsRichAttributedText(rt, size: readerSettings.paragraphSize)
        case .listItem(let text, _, _):
            // Sentence offsets are in the unprefixed text. Assumes the bullet/number prefix fits on the first line so it only shifts x, not y — may drift at extreme font sizes or narrow widths.
            return nsStyledText(text, size: readerSettings.paragraphSize, weight: .regular)
        default:
            return nsStyledText(textForAnalysis(item), size: readerSettings.paragraphSize, weight: .regular)
        }
    }

    // Exact NSAttributedString that HighlightableTextView renders for a splittable item.
    // Used by Paginator to measure line fragments so page breaks land on real line boundaries.
    // Returns nil for items that are not rendered via HighlightableTextView.
    func renderedAttributedText(for item: ReadableItem) -> NSAttributedString? {
        switch item {
        case .title(let text):
            return nsStyledText(text, size: readerSettings.titleSize, weight: .bold)
        case .byline(let text):
            return nsStyledText(text, size: readerSettings.bylineSize, weight: .semibold)
        case .paragraph(let text):
            return nsStyledText(text, size: readerSettings.paragraphSize, weight: .regular)
        case .richParagraph(let rt):
            return nsRichAttributedText(rt, size: readerSettings.paragraphSize)
        case .subheading(let text):
            return nsStyledText(text, size: readerSettings.titleSize - 4, weight: .bold)
        case .listItem(let text, let ordered, let listIdx):
            let prefix = ordered ? "\(listIdx). " : "\u{2022} "
            return nsStyledText(prefix + text, size: readerSettings.paragraphSize, weight: .regular)
        case .image, .blockquote, .code, .divider, .callout, .paragraphWithFootnotes, .chapterTOC:
            return nil
        }
    }

    private func styledFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        var font = UIFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = font.fontDescriptor.withDesign(readerSettings.fontFamily.uiDesign) {
            font = UIFont(descriptor: descriptor, size: size)
        }
        return font
    }

    private func paragraphStyle(for size: CGFloat) -> NSParagraphStyle {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = readerSettings.lineSpacingPt(for: size)
        return para
    }

    func nsStyledText(_ text: String, size: CGFloat, weight: UIFont.Weight) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: styledFont(size: size, weight: weight),
            .foregroundColor: UIColor(white: 0.92, alpha: 1.0),
            .paragraphStyle: paragraphStyle(for: size)
        ])
    }

    func nsRichAttributedText(_ rt: RichText, size: CGFloat) -> NSAttributedString {
        let ns = rt.attributedString
        let result = NSMutableAttributedString()
        let para = paragraphStyle(for: size)
        ns.enumerateAttributes(in: NSRange(location: 0, length: ns.length)) { attrs, range, _ in
            let substring = ns.attributedSubstring(from: range).string
            let uiFont = attrs[.font] as? UIFont
            let traits = uiFont?.fontDescriptor.symbolicTraits ?? []
            let isBold = traits.contains(.traitBold)
            let isItalic = traits.contains(.traitItalic)
            var font = styledFont(size: size, weight: isBold ? .bold : .regular)
            if isItalic, let italicDesc = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
                font = UIFont(descriptor: italicDesc, size: size)
            }
            let chunk = NSAttributedString(string: substring, attributes: [
                .font: font,
                .foregroundColor: UIColor(white: 0.92, alpha: 1.0),
                .paragraphStyle: para
            ])
            result.append(chunk)
        }
        return result
    }
}
