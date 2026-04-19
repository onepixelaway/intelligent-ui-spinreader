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
        var guid: String?
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

        if name == "item" || name == "entry" {
            currentItem = ParsedItem()
            currentText = ""
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
            var consumed = true
            switch name {
            case "title":
                currentItem?.title = trimmed
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
                    currentItem?.author = trimmed
                }
            case "name":
                if (currentItem?.author?.isEmpty ?? true),
                   !trimmed.isEmpty,
                   elementStack.dropLast().last == "author" {
                    currentItem?.author = trimmed
                }
            case "guid", "id":
                if currentItem?.guid == nil { currentItem?.guid = trimmed }
            default:
                consumed = false
            }
            if consumed { currentText = "" }
            return
        }

        if name == "title", feedTitle.isEmpty {
            let parents = elementStack.dropLast()
            if parents.contains(where: { $0 == "channel" || $0 == "feed" }) {
                feedTitle = trimmed
                currentText = ""
            }
        }
    }
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

    let entities: [(String, String)] = [
        ("&nbsp;", " "),
        ("&amp;", "&"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&#39;", "'"),
        ("&apos;", "'"),
        ("&hellip;", "…"),
        ("&mdash;", "—"),
        ("&ndash;", "–"),
        ("&rsquo;", "’"),
        ("&lsquo;", "‘"),
        ("&rdquo;", "”"),
        ("&ldquo;", "“"),
    ]
    for (pattern, replacement) in entities {
        text = text.replacingOccurrences(of: pattern, with: replacement)
    }

    text = text.replacingOccurrences(
        of: "\\n[ \\t]*\\n([ \\t]*\\n)+",
        with: "\n\n",
        options: .regularExpression
    )
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
