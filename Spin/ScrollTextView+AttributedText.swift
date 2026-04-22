import SwiftUI
import UIKit

extension ScrollTextView {
    // Attributed text matching what `readableItemView` renders for a given item.
    // Covers the three `isHighlightableBody` cases; falls back to plain styling for others.
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

    func nsStyledText(_ text: String, size: CGFloat, weight: UIFont.Weight) -> NSAttributedString {
        var font = UIFont.systemFont(ofSize: size, weight: weight)
        let design = readerSettings.fontFamily.uiDesign
        if let descriptor = font.fontDescriptor.withDesign(design) {
            font = UIFont(descriptor: descriptor, size: size)
        }
        let para = NSMutableParagraphStyle()
        para.lineSpacing = readerSettings.lineSpacingPt(for: size)
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor(white: 0.92, alpha: 1.0),
            .paragraphStyle: para
        ])
    }

    func nsRichAttributedText(_ rt: RichText, size: CGFloat) -> NSAttributedString {
        let ns = rt.attributedString
        let result = NSMutableAttributedString()
        let design = readerSettings.fontFamily.uiDesign
        let para = NSMutableParagraphStyle()
        para.lineSpacing = readerSettings.lineSpacingPt(for: size)
        ns.enumerateAttributes(in: NSRange(location: 0, length: ns.length)) { attrs, range, _ in
            let substring = ns.attributedSubstring(from: range).string
            let uiFont = attrs[.font] as? UIFont
            let traits = uiFont?.fontDescriptor.symbolicTraits ?? []
            let isBold = traits.contains(.traitBold)
            let isItalic = traits.contains(.traitItalic)
            let weight: UIFont.Weight = isBold ? .bold : .regular
            var font = UIFont.systemFont(ofSize: size, weight: weight)
            if let descriptor = font.fontDescriptor.withDesign(design) {
                font = UIFont(descriptor: descriptor, size: size)
            }
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
