import SwiftUI
import UIKit
import SafariServices

struct ArticleImageView: View {
    let url: URL
    let alt: String?
    let caption: String?

    @EnvironmentObject private var settings: ReaderSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.2))) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                case .failure:
                    placeholder
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: 24, weight: .light))
                                .foregroundColor(.gray.opacity(0.4))
                        }
                default:
                    placeholder
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: settings.captionSize, weight: .regular, design: settings.fontFamily.design).italic())
                    .foregroundColor(.gray.opacity(0.65))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                    .padding(.horizontal, 4)
            }
        }
        .accessibilityLabel(alt ?? caption ?? "Image")
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Color.white.opacity(0.04))
    }
}

struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ControlPanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ParagraphPositionKey: PreferenceKey {
    typealias Value = [Int: CGRect]

    static let defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

struct AccentedQuoteView: View {
    let text: String
    let barOpacity: Double
    let textWhite: Double
    let hasBackground: Bool

    @EnvironmentObject private var settings: ReaderSettings

    init(text: String, barOpacity: Double = 0.25, textWhite: Double = 0.78, hasBackground: Bool = false) {
        self.text = text
        self.barOpacity = barOpacity
        self.textWhite = textWhite
        self.hasBackground = hasBackground
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.white.opacity(barOpacity))
                .frame(width: 3)

            StaticAttributedTextView(attributedText: attributedText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(text)
        }
        .padding(.horizontal, hasBackground ? 12 : 0)
        .padding(.vertical, hasBackground ? 14 : 0)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(hasBackground ? 0.06 : 0))
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributedText: NSAttributedString {
        let size = settings.blockquoteSize
        var font = UIFont.systemFont(ofSize: size, weight: .regular)
        if let descriptor = font.fontDescriptor.withDesign(settings.fontFamily.uiDesign) {
            font = UIFont(descriptor: descriptor, size: size)
        }
        if let italicDescriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
            font = UIFont(descriptor: italicDescriptor, size: size)
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = settings.lineSpacingPt(for: size)

        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor(white: textWhite, alpha: 1.0),
            .paragraphStyle: paragraphStyle
        ])
    }
}

struct StaticAttributedTextView: UIViewRepresentable {
    let attributedText: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.clipsToBounds = true
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        guard !textView.attributedText.isEqual(to: attributedText) else { return }
        textView.attributedText = attributedText
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingCompressedSize.width
        let size = uiView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }
}

struct ChapterTOCView: View {
    let entries: [String]

    @EnvironmentObject private var settings: ReaderSettings

    private static let linkColor = Color(red: 0.4, green: 0.6, blue: 0.9)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                Text(entry)
                    .font(.system(size: settings.paragraphSize, weight: .regular, design: settings.fontFamily.design))
                    .foregroundColor(Self.linkColor)
                    .lineSpacing(settings.lineSpacingPt(for: settings.paragraphSize))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if index < entries.count - 1 {
                    Divider()
                        .opacity(0.12)
                        .padding(.vertical, 4)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
    }
}

struct FootnoteParagraphView: View {
    let text: String
    let footnotes: [ScrollTextView.FootnoteRef]
    @Binding var activeFootnote: String?

    @EnvironmentObject private var settings: ReaderSettings

    var body: some View {
        Text(buildAttributedString())
            .lineSpacing(settings.lineSpacingPt(for: settings.paragraphSize))
            .fixedSize(horizontal: false, vertical: true)
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "footnote", let marker = url.host() {
                    if let fn = footnotes.first(where: { $0.marker == marker }) {
                        activeFootnote = fn.content
                    }
                }
                return .handled
            })
    }

    private func buildAttributedString() -> AttributedString {
        let footnoteMarkers = Set(footnotes.map { $0.marker })
        let pattern = "\\[(\\d+)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return styledPlain(text)
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        if matches.isEmpty {
            return styledPlain(text)
        }

        var result = AttributedString()
        var lastEnd = 0

        for match in matches {
            let matchRange = match.range
            let markerRange = match.range(at: 1)
            let marker = nsText.substring(with: markerRange)

            if matchRange.location > lastEnd {
                let before = nsText.substring(with: NSRange(location: lastEnd, length: matchRange.location - lastEnd))
                result.append(styledPlain(before))
            }

            if footnoteMarkers.contains(marker) {
                var markerStr = AttributedString("[\(marker)]")
                markerStr.font = .system(size: settings.paragraphSize * 0.7, weight: .medium, design: settings.fontFamily.design)
                markerStr.foregroundColor = Color(red: 0.55, green: 0.7, blue: 0.9)
                markerStr.baselineOffset = settings.paragraphSize * 0.3
                markerStr.link = URL(string: "footnote://\(marker)")
                result.append(markerStr)
            } else {
                result.append(styledPlain("[\(marker)]"))
            }

            lastEnd = matchRange.location + matchRange.length
        }

        if lastEnd < nsText.length {
            let remaining = nsText.substring(from: lastEnd)
            result.append(styledPlain(remaining))
        }

        return result
    }

    private func styledPlain(_ str: String) -> AttributedString {
        var attr = AttributedString(str)
        attr.font = .system(size: settings.paragraphSize, weight: .regular, design: settings.fontFamily.design)
        attr.foregroundColor = Color(white: 0.92)
        return attr
    }
}

struct FootnoteOverlay: View {
    let text: String
    let onDismiss: () -> Void

    @EnvironmentObject private var settings: ReaderSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Footnote")
                    .font(.system(size: settings.paragraphSize - 2, weight: .semibold, design: settings.fontFamily.design))
                    .foregroundColor(Color(white: 0.7))
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(Color(white: 0.5))
                }
            }
            Text(text)
                .font(.system(size: settings.paragraphSize - 1, weight: .regular, design: settings.fontFamily.design))
                .foregroundColor(Color(white: 0.88))
                .lineSpacing(settings.lineSpacingPt(for: settings.paragraphSize - 1))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 0.15))
                .shadow(color: .black.opacity(0.5), radius: 10, y: -4)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .onTapGesture {
            onDismiss()
        }
    }
}

struct CodeBlockView: View {
    let text: String

    @EnvironmentObject private var settings: ReaderSettings

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(size: settings.codeSize, design: .monospaced))
                .foregroundColor(Color(white: 0.88))
                .padding(14)
                .fixedSize(horizontal: true, vertical: false)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.10, green: 0.10, blue: 0.10))
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
