import Foundation

final class RSSParser: NSObject, XMLParserDelegate {
    struct ParsedFeed: Sendable {
        var title: String
        var items: [ParsedItem]
    }

    struct ParsedItem: Sendable {
        var title: String = ""
        var link: String?
        var description: String = ""
        var content: String = ""
        var pubDate: String?
        var author: String?
        var category: String?
        var guid: String?
        var mediaContent: String?
    }

    private var feedTitle: String = ""
    private var items: [ParsedItem] = []
    private var elementStack: [String] = []
    private var currentItem: ParsedItem?
    private var currentText: String = ""

    func parse(data: Data) -> ParsedFeed? {
        feedTitle = ""
        items = []
        elementStack = []
        currentItem = nil
        currentText = ""

        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return nil }
        return ParsedFeed(title: feedTitle, items: items)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.lowercased()
        elementStack.append(name)
        currentText = ""

        if name == "item" || name == "entry" {
            currentItem = ParsedItem()
            return
        }

        if name == "link", currentItem != nil, let href = attributeDict["href"] {
            let rel = attributeDict["rel"] ?? "alternate"
            if rel == "alternate" {
                currentItem?.link = href
            } else if currentItem?.link == nil {
                currentItem?.link = href
            }
        }

        if name == "category", currentItem != nil,
           (currentItem?.category?.isEmpty ?? true),
           let term = attributeDict["term"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !term.isEmpty {
            currentItem?.category = decodeHTMLEntities(term)
        }

        if currentItem != nil,
           currentItem?.mediaContent == nil,
           name == "media:content" || name == "media:thumbnail",
           let href = attributeDict["url"], !href.isEmpty {
            let medium = attributeDict["medium"]?.lowercased()
            let typeAttr = attributeDict["type"]?.lowercased() ?? ""
            if medium == nil || medium == "image" || typeAttr.hasPrefix("image/") {
                currentItem?.mediaContent = href
            }
        }

        if currentItem != nil,
           currentItem?.mediaContent == nil,
           name == "enclosure",
           let href = attributeDict["url"], !href.isEmpty,
           (attributeDict["type"]?.lowercased() ?? "").hasPrefix("image/") {
            currentItem?.mediaContent = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) {
            currentText += s
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        defer {
            if elementStack.last == name { elementStack.removeLast() }
        }

        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if name == "item" || name == "entry" {
            if let item = currentItem { items.append(item) }
            currentItem = nil
            currentText = ""
            return
        }

        if currentItem != nil {
            switch name {
            case "title":
                currentItem?.title = decodeHTMLEntities(trimmed)
            case "link":
                if (currentItem?.link?.isEmpty ?? true), !trimmed.isEmpty {
                    currentItem?.link = trimmed
                }
            case "description", "summary":
                if currentItem?.description.isEmpty == true {
                    currentItem?.description = currentText
                }
            case "content:encoded", "encoded", "content":
                currentItem?.content = currentText
            case "pubdate", "published", "updated":
                if currentItem?.pubDate == nil { currentItem?.pubDate = trimmed }
            case "author", "dc:creator", "creator":
                if (currentItem?.author?.isEmpty ?? true), !trimmed.isEmpty {
                    currentItem?.author = decodeHTMLEntities(trimmed)
                }
            case "name":
                if (currentItem?.author?.isEmpty ?? true),
                   !trimmed.isEmpty,
                   elementStack.dropLast().last == "author" {
                    currentItem?.author = decodeHTMLEntities(trimmed)
                }
            case "category":
                if (currentItem?.category?.isEmpty ?? true), !trimmed.isEmpty {
                    currentItem?.category = decodeHTMLEntities(trimmed)
                }
            case "guid", "id":
                if currentItem?.guid == nil { currentItem?.guid = trimmed }
            default:
                break
            }
            return
        }

        if name == "title", feedTitle.isEmpty {
            let parents = elementStack.dropLast()
            if parents.contains(where: { $0 == "channel" || $0 == "feed" }) {
                feedTitle = decodeHTMLEntities(trimmed)
            }
        }
    }
}

private let contentBlockRegex = try! NSRegularExpression(
    pattern: #"<figure\b[^>]*>[\s\S]*?</figure>|<blockquote\b[^>]*>[\s\S]*?</blockquote>|<pre\b[^>]*>[\s\S]*?</pre>|<iframe\b[^>]*>[\s\S]*?</iframe>|<iframe\b[^>]*/?>|<img\b[^>]*/?>"#,
    options: .caseInsensitive
)
private let blockquoteRegex = try! NSRegularExpression(
    pattern: #"<blockquote\b[^>]*>([\s\S]*?)</blockquote>"#,
    options: .caseInsensitive
)
private let preRegex = try! NSRegularExpression(
    pattern: #"<pre\b[^>]*>([\s\S]*?)</pre>"#,
    options: .caseInsensitive
)
private let youtubeIDRegex = try! NSRegularExpression(
    pattern: #"(?:youtube\.com/watch\?(?:[^&]+&)*v=|youtube\.com/embed/|youtube\.com/v/|youtu\.be/|youtube-nocookie\.com/embed/)([A-Za-z0-9_-]{11})"#,
    options: .caseInsensitive
)
private let vimeoIDRegex = try! NSRegularExpression(
    pattern: #"(?:vimeo\.com/(?:video/|channels/[^/]+/|groups/[^/]+/videos/)?|player\.vimeo\.com/video/)(\d+)"#,
    options: .caseInsensitive
)

func parseContentBlocks(_ html: String) -> [ContentBlock] {
    guard !html.isEmpty else { return [] }

    let nsString = html as NSString
    let fullRange = NSRange(location: 0, length: nsString.length)
    let matches = contentBlockRegex.matches(in: html, range: fullRange)

    guard !matches.isEmpty else { return textBlocks(from: html) }

    var blocks: [ContentBlock] = []
    var cursor = 0

    for match in matches {
        let range = match.range
        if range.location > cursor {
            let chunk = nsString.substring(with: NSRange(location: cursor, length: range.location - cursor))
            blocks.append(contentsOf: textBlocks(from: chunk))
        }
        let fragment = nsString.substring(with: range)
        if let block = parseFragmentBlock(fragment) {
            blocks.append(block)
        }
        cursor = range.location + range.length
    }

    if cursor < nsString.length {
        let trailing = nsString.substring(from: cursor)
        blocks.append(contentsOf: textBlocks(from: trailing))
    }

    return blocks
}

private func parseFragmentBlock(_ fragment: String) -> ContentBlock? {
    let lower = fragment.lowercased()
    if lower.hasPrefix("<blockquote") {
        return parseBlockquoteFragment(fragment)
    }
    if lower.hasPrefix("<pre") {
        return parseCodeFragment(fragment)
    }
    if lower.hasPrefix("<iframe") {
        return parseIframeFragment(fragment)
    }
    return parseMediaFragment(fragment)
}

private func firstCaptureGroup(_ regex: NSRegularExpression, in string: String) -> String? {
    let ns = string as NSString
    guard let match = regex.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)),
          match.numberOfRanges > 1 else { return nil }
    return ns.substring(with: match.range(at: 1))
}

private func parseBlockquoteFragment(_ fragment: String) -> ContentBlock? {
    guard let inner = firstCaptureGroup(blockquoteRegex, in: fragment) else { return nil }
    let text = stripHTML(inner)
    return text.isEmpty ? nil : .blockquote(text)
}

private func parseCodeFragment(_ fragment: String) -> ContentBlock? {
    guard let inner = firstCaptureGroup(preRegex, in: fragment) else { return nil }
    let trimmed = stripHTML(inner)
    return trimmed.isEmpty ? nil : .code(trimmed)
}

private func parseIframeFragment(_ fragment: String) -> ContentBlock? {
    guard let src = firstHTMLAttribute(fragment, name: "src") else { return nil }
    let decoded = decodeHTMLEntities(src)
    return videoBlock(from: decoded)
}

func videoBlock(from urlString: String) -> ContentBlock? {
    guard let url = URL(string: urlString) else { return nil }
    if let id = firstCaptureGroup(youtubeIDRegex, in: urlString) {
        let target = URL(string: "https://www.youtube.com/watch?v=\(id)") ?? url
        let thumb = URL(string: "https://img.youtube.com/vi/\(id)/hqdefault.jpg")
        return .video(videoURL: target, thumbnailURL: thumb, provider: .youtube)
    }
    if let id = firstCaptureGroup(vimeoIDRegex, in: urlString) {
        let target = URL(string: "https://vimeo.com/\(id)") ?? url
        return .video(videoURL: target, thumbnailURL: nil, provider: .vimeo)
    }
    return nil
}

private func textBlocks(from html: String) -> [ContentBlock] {
    let stripped = stripHTML(html)
    guard !stripped.isEmpty else { return [] }
    return stripped
        .components(separatedBy: "\n\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .map { paragraph -> ContentBlock in
            if let video = videoBlockFromParagraph(paragraph) { return video }
            return .text(paragraph)
        }
}

private func videoBlockFromParagraph(_ paragraph: String) -> ContentBlock? {
    let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.contains(where: \.isWhitespace) else { return nil }
    guard trimmed.lowercased().hasPrefix("http") else { return nil }
    return videoBlock(from: trimmed)
}

private func parseMediaFragment(_ fragment: String) -> ContentBlock? {
    guard let src = firstHTMLAttribute(fragment, name: "src"),
          let url = URL(string: decodeHTMLEntities(src)) else { return nil }

    let alt = firstHTMLAttribute(fragment, name: "alt").map { decodeHTMLEntities($0) }
    let caption = firstFigcaption(fragment)

    let trimmedAlt = alt?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedCaption = caption?.trimmingCharacters(in: .whitespacesAndNewlines)

    return .image(
        url: url,
        alt: (trimmedAlt?.isEmpty == false) ? trimmedAlt : nil,
        caption: (trimmedCaption?.isEmpty == false) ? trimmedCaption : nil
    )
}

private func firstHTMLAttribute(_ html: String, name: String) -> String? {
    let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
    let nsString = html as NSString
    let range = NSRange(location: 0, length: nsString.length)
    guard let match = regex.firstMatch(in: html, range: range) else { return nil }
    for index in 1...3 {
        let r = match.range(at: index)
        if r.location != NSNotFound { return nsString.substring(with: r) }
    }
    return nil
}

private func firstFigcaption(_ html: String) -> String? {
    let pattern = #"<figcaption\b[^>]*>([\s\S]*?)</figcaption>"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
    let nsString = html as NSString
    let range = NSRange(location: 0, length: nsString.length)
    guard let match = regex.firstMatch(in: html, range: range), match.numberOfRanges > 1 else { return nil }
    let inner = nsString.substring(with: match.range(at: 1))
    let text = stripHTML(inner)
    return text.isEmpty ? nil : text
}

func stripHTML(_ html: String) -> String {
    var text = html
    let blockReplacements: [(String, String)] = [
        ("</p>", "\n\n"),
        ("<br />", "\n"),
        ("<br/>", "\n"),
        ("<br>", "\n"),
        ("</div>", "\n"),
        ("</li>", "\n"),
    ]
    for (pattern, replacement) in blockReplacements {
        text = text.replacingOccurrences(
            of: pattern,
            with: replacement,
            options: .caseInsensitive
        )
    }
    text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    text = decodeHTMLEntities(text)

    text = text.replacingOccurrences(
        of: "\\n[ \\t]*\\n([ \\t]*\\n)+",
        with: "\n\n",
        options: .regularExpression
    )
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

private let htmlNamedEntities: [String: String] = [
    "nbsp": "\u{00A0}",
    "amp": "&",
    "lt": "<",
    "gt": ">",
    "quot": "\"",
    "apos": "'",
    "hellip": "…",
    "mdash": "—",
    "ndash": "–",
    "rsquo": "\u{2019}",
    "lsquo": "\u{2018}",
    "rdquo": "\u{201D}",
    "ldquo": "\u{201C}",
    "sbquo": "\u{201A}",
    "bdquo": "\u{201E}",
    "copy": "©",
    "reg": "®",
    "trade": "™",
    "middot": "·",
    "bull": "•",
    "laquo": "«",
    "raquo": "»",
    "deg": "°",
    "times": "×",
    "divide": "÷",
    "pound": "£",
    "euro": "€",
    "yen": "¥",
    "cent": "¢",
]

func decodeHTMLEntities(_ input: String) -> String {
    guard input.contains("&") else { return input }

    var result = ""
    result.reserveCapacity(input.count)
    var cursor = input.startIndex

    while let ampIndex = input[cursor...].firstIndex(of: "&") {
        result.append(contentsOf: input[cursor..<ampIndex])
        let afterAmp = input.index(after: ampIndex)
        let searchEnd = input.index(afterAmp, offsetBy: 10, limitedBy: input.endIndex) ?? input.endIndex

        if let semiIndex = input[afterAmp..<searchEnd].firstIndex(of: ";"),
           let replacement = decodeEntityBody(input[afterAmp..<semiIndex]) {
            result.append(replacement)
            cursor = input.index(after: semiIndex)
        } else {
            result.append("&")
            cursor = afterAmp
        }
    }

    result.append(contentsOf: input[cursor...])
    return result
}

private func decodeEntityBody(_ body: Substring) -> String? {
    guard !body.isEmpty else { return nil }
    if body.first == "#" {
        let numeric = body.dropFirst()
        guard !numeric.isEmpty else { return nil }
        let code: UInt32?
        if let first = numeric.first, first == "x" || first == "X" {
            code = UInt32(numeric.dropFirst(), radix: 16)
        } else {
            code = UInt32(numeric)
        }
        guard let code, let scalar = Unicode.Scalar(code) else { return nil }
        return String(Character(scalar))
    }
    return htmlNamedEntities[String(body)]
}

nonisolated(unsafe) private let rfc822Formatters: [DateFormatter] = {
    let locale = Locale(identifier: "en_US_POSIX")
    let formats = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yyyy HH:mm:ss Z",
        "dd MMM yyyy HH:mm:ss Z",
        "yyyy-MM-dd'T'HH:mm:ssZ",
    ]
    return formats.map { format in
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = format
        return formatter
    }
}()

nonisolated(unsafe) private let isoFormatterFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

nonisolated(unsafe) private let isoFormatterPlain: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

func parseFeedDate(_ raw: String?) -> Date? {
    guard let raw, !raw.isEmpty else { return nil }
    if let date = isoFormatterFractional.date(from: raw) { return date }
    if let date = isoFormatterPlain.date(from: raw) { return date }
    for formatter in rfc822Formatters {
        if let date = formatter.date(from: raw) { return date }
    }
    return nil
}
