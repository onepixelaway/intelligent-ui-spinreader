import SwiftUI
import UIKit

extension ScrollTextView {
    var firstTitleIndex: Int? {
        items.firstIndex(where: {
            if case .title = $0 { return true }
            return false
        })
    }

    func isPrimaryTitle(at index: Int) -> Bool {
        firstTitleIndex == index
    }

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

    // Exact NSAttributedString that HighlightableTextView renders.
    // Returns nil for items that are not rendered via HighlightableTextView.
    func renderedAttributedText(for item: ReadableItem, at index: Int) -> NSAttributedString? {
        switch item {
        case .title(let text):
            return nsHeaderText(text, size: titleSize(isPrimary: isPrimaryTitle(at: index)), isPrimary: isPrimaryTitle(at: index))
        case .byline(let text):
            return nsStyledText(text, size: readerSettings.bylineSize, weight: .semibold)
        case .paragraph(let text):
            return nsStyledText(text, size: readerSettings.paragraphSize, weight: .regular)
        case .richParagraph(let rt):
            return nsRichAttributedText(rt, size: readerSettings.paragraphSize)
        case .subheading(let text):
            return nsHeaderText(text, size: readerSettings.titleSize - 4)
        case .listItem(let text, let ordered, let listIdx):
            let prefix = ordered ? "\(listIdx). " : "\u{2022} "
            return nsStyledText(prefix + text, size: readerSettings.paragraphSize, weight: .regular)
        case .image, .blockquote, .code, .divider, .callout, .paragraphWithFootnotes, .chapterTOC:
            return nil
        }
    }

    // Text attributes used only for measuring page breaks. This includes custom SwiftUI text
    // renderers like block quotes so they can still avoid mid-line clipping.
    func paginationAttributedText(for item: ReadableItem, at index: Int) -> NSAttributedString? {
        switch item {
        case .blockquote(let text), .callout(let text):
            return nsBlockquoteText(text)
        case .paragraphWithFootnotes(let text, _):
            return nsStyledText(text, size: readerSettings.paragraphSize, weight: .regular)
        case .title, .byline, .paragraph, .richParagraph, .subheading, .listItem:
            return renderedAttributedText(for: item, at: index)
        case .image, .code, .divider, .chapterTOC:
            return nil
        }
    }

    func titleSize(isPrimary: Bool) -> CGFloat {
        isPrimary ? readerSettings.titleSize * 1.4 : readerSettings.titleSize
    }

    func nsHeaderText(_ text: String, size: CGFloat, isPrimary: Bool = false) -> NSAttributedString {
        let font: UIFont
        var kern: CGFloat = 0
        if isPrimary {
            font = UIFont(name: "DMSans-Black", size: size) ?? UIFont.systemFont(ofSize: size, weight: .black)
            kern = -0.4
        } else {
            switch readerSettings.readerHeaderFont {
            case .dmSansBold:
                font = UIFont(name: "DMSans-Bold", size: size) ?? UIFont.systemFont(ofSize: size, weight: .bold)
                kern = -0.4
            case .systemDefault:
                font = UIFont.systemFont(ofSize: size, weight: .bold)
            }
        }
        let para: NSParagraphStyle
        if isPrimary {
            let primaryPara = NSMutableParagraphStyle()
            primaryPara.minimumLineHeight = size * 1.1
            primaryPara.maximumLineHeight = size * 1.1
            para = primaryPara
        } else {
            para = paragraphStyle(for: size)
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(white: 0.92, alpha: 1.0),
            .paragraphStyle: para
        ]
        if kern != 0 {
            attrs[.kern] = kern
        }
        return NSAttributedString(string: text, attributes: attrs)
    }

    private func styledFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        switch readerSettings.readerBodyFont {
        case .systemSF:
            return UIFont.systemFont(ofSize: size, weight: weight)
        case .systemSerif:
            var font = UIFont.systemFont(ofSize: size, weight: weight)
            if let descriptor = font.fontDescriptor.withDesign(.serif) {
                font = UIFont(descriptor: descriptor, size: size)
            }
            return font
        case .dmSansRegular:
            let name = weight.rawValue >= UIFont.Weight.semibold.rawValue ? "DMSans-Bold" : "DMSans-Regular"
            return UIFont(name: name, size: size) ?? UIFont.systemFont(ofSize: size, weight: weight)
        }
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

    private func nsBlockquoteText(_ text: String) -> NSAttributedString {
        let size = readerSettings.blockquoteSize
        var font = styledFont(size: size, weight: .regular)
        if let italicDescriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
            font = UIFont(descriptor: italicDescriptor, size: size)
        }

        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor(white: 0.78, alpha: 1.0),
            .paragraphStyle: paragraphStyle(for: size)
        ])
    }
}
