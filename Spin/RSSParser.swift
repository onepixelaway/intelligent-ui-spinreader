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
