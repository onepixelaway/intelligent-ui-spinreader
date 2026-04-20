import Foundation
import Compression

struct EpubBook: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let author: String
    let chapters: [EpubChapter]
    let fileURL: URL

    static func == (lhs: EpubBook, rhs: EpubBook) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct EpubChapter: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let items: [ScrollTextView.ReadableItem]
}

enum EpubParserError: LocalizedError {
    case fileReadFailed
    case invalidZip
    case missingContainer
    case missingOPF
    case decompressionFailed
    case unsupportedCompression(UInt16)

    var errorDescription: String? {
        switch self {
        case .fileReadFailed: return "Couldn't read the file."
        case .invalidZip: return "The file isn't a valid ePub archive."
        case .missingContainer: return "ePub is missing META-INF/container.xml."
        case .missingOPF: return "ePub is missing its OPF manifest."
        case .decompressionFailed: return "Couldn't decompress the ePub contents."
        case .unsupportedCompression(let m): return "Unsupported ZIP compression method (\(m))."
        }
    }
}

enum EpubParser {
    static func parse(fileURL: URL) throws -> EpubBook {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw EpubParserError.fileReadFailed
        }

        let archive = try ZipArchive(data: data)

        guard let containerData = try archive.fileData(named: "META-INF/container.xml") else {
            throw EpubParserError.missingContainer
        }
        guard let opfPath = parseContainerXML(containerData) else {
            throw EpubParserError.missingContainer
        }

        guard let opfData = try archive.fileData(named: opfPath) else {
            throw EpubParserError.missingOPF
        }
        let opf = parseOPF(opfData)

        let opfBase: String = {
            if let lastSlash = opfPath.lastIndex(of: "/") {
                return String(opfPath[opfPath.startIndex...lastSlash])
            }
            return ""
        }()

        var chapters: [EpubChapter] = []
        for itemId in opf.spineIDs {
            guard let href = opf.manifestById[itemId] else { continue }
            let decodedHref = href.removingPercentEncoding ?? href
            let fullPath = normalize(opfBase + decodedHref)
            guard let chapterData = try? archive.fileData(named: fullPath),
                  let xhtml = String(data: chapterData, encoding: .utf8)
                          ?? String(data: chapterData, encoding: .isoLatin1)
            else { continue }

            let items = EpubHTMLExtractor.extractItems(from: xhtml)
            guard !items.isEmpty else { continue }

            let chapterTitle: String = {
                if case .title(let t) = items.first { return t }
                return "Chapter \(chapters.count + 1)"
            }()
            chapters.append(EpubChapter(id: chapters.count, title: chapterTitle, items: items))
        }

        let title = opf.title.isEmpty ? fileURL.deletingPathExtension().lastPathComponent : opf.title
        return EpubBook(
            id: fileURL.lastPathComponent,
            title: title,
            author: opf.author,
            chapters: chapters,
            fileURL: fileURL
        )
    }

    private static func normalize(_ path: String) -> String {
        var components: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: false) {
            if part == ".." {
                if !components.isEmpty { components.removeLast() }
            } else if part != "." && !part.isEmpty {
                components.append(String(part))
            }
        }
        return components.joined(separator: "/")
    }

    private static func parseContainerXML(_ data: Data) -> String? {
        let parser = XMLParser(data: data)
        let delegate = ContainerXMLParserDelegate()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.parse()
        return delegate.rootfilePath
    }

    private static func parseOPF(_ data: Data) -> OPFContents {
        let parser = XMLParser(data: data)
        let delegate = OPFParserDelegate()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.parse()
        return OPFContents(
            title: delegate.title,
            author: delegate.author,
            manifestById: delegate.manifestById,
            spineIDs: delegate.spineIDs
        )
    }
}

private struct OPFContents {
    let title: String
    let author: String
    let manifestById: [String: String]
    let spineIDs: [String]
}

private final class ContainerXMLParserDelegate: NSObject, XMLParserDelegate {
    var rootfilePath: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "rootfile", let path = attributeDict["full-path"], rootfilePath == nil {
            rootfilePath = path
        }
    }
}

private final class OPFParserDelegate: NSObject, XMLParserDelegate {
    var title: String = ""
    var author: String = ""
    var manifestById: [String: String] = [:]
    var spineIDs: [String] = []

    private var currentElement: String = ""
    private var buffer: String = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        buffer = ""

        if elementName == "item",
           let id = attributeDict["id"],
           let href = attributeDict["href"] {
            manifestById[id] = href
        }
        if elementName == "itemref", let idref = attributeDict["idref"] {
            spineIDs.append(idref)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if elementName == "title", title.isEmpty, !trimmed.isEmpty {
            title = trimmed
        }
        if elementName == "creator", author.isEmpty, !trimmed.isEmpty {
            author = trimmed
        }
        buffer = ""
    }
}

// MARK: - Minimal ZIP reader

private final class ZipArchive {
    private struct Entry {
        let path: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    private var entries: [String: Entry] = [:]

    init(data: Data) throws {
        self.data = data
        try parseCentralDirectory()
    }

    func fileData(named path: String) throws -> Data? {
        guard let entry = entries[path] else { return nil }

        let headerOffset = entry.localHeaderOffset
        guard headerOffset + 30 <= data.count else { throw EpubParserError.invalidZip }
        guard readU32LE(at: headerOffset) == 0x04034b50 else {
            throw EpubParserError.invalidZip
        }
        let nameLen = Int(readU16LE(at: headerOffset + 26))
        let extraLen = Int(readU16LE(at: headerOffset + 28))
        let dataStart = headerOffset + 30 + nameLen + extraLen
        let compressedSize = entry.compressedSize
        guard dataStart + compressedSize <= data.count else {
            throw EpubParserError.invalidZip
        }

        let compressed = sliceCopy(from: dataStart, length: compressedSize)

        switch entry.method {
        case 0:
            return compressed
        case 8:
            return try inflateRawDeflate(compressed, expectedSize: entry.uncompressedSize)
        default:
            throw EpubParserError.unsupportedCompression(entry.method)
        }
    }

    private func parseCentralDirectory() throws {
        let eocdSig: UInt32 = 0x06054b50
        let maxCommentLen = 65535
        let minSearch = max(0, data.count - (maxCommentLen + 22))
        var eocdOffset: Int?
        if data.count >= 22 {
            for i in stride(from: data.count - 22, through: minSearch, by: -1) {
                if readU32LE(at: i) == eocdSig {
                    eocdOffset = i
                    break
                }
            }
        }
        guard let eocd = eocdOffset else { throw EpubParserError.invalidZip }

        let totalEntries = Int(readU16LE(at: eocd + 10))
        let centralDirOffset = Int(readU32LE(at: eocd + 16))

        var offset = centralDirOffset
        for _ in 0..<totalEntries {
            guard offset + 46 <= data.count else { throw EpubParserError.invalidZip }
            guard readU32LE(at: offset) == 0x02014b50 else {
                throw EpubParserError.invalidZip
            }

            let method = readU16LE(at: offset + 10)
            let compressedSize = Int(readU32LE(at: offset + 20))
            let uncompressedSize = Int(readU32LE(at: offset + 24))
            let nameLen = Int(readU16LE(at: offset + 28))
            let extraLen = Int(readU16LE(at: offset + 30))
            let commentLen = Int(readU16LE(at: offset + 32))
            let localOffset = Int(readU32LE(at: offset + 42))

            let nameStart = offset + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd <= data.count else { throw EpubParserError.invalidZip }
            let nameData = sliceCopy(from: nameStart, length: nameLen)
            let path = String(data: nameData, encoding: .utf8) ?? ""

            if !path.isEmpty {
                entries[path] = Entry(
                    path: path,
                    method: method,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localOffset
                )
            }

            offset = nameEnd + extraLen + commentLen
        }
    }

    private func sliceCopy(from offset: Int, length: Int) -> Data {
        let start = data.startIndex + offset
        let end = start + length
        return data.subdata(in: start..<end)
    }

    private func readU16LE(at offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        return UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
    }

    private func readU32LE(at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i])
            | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
    }

    private func inflateRawDeflate(_ compressed: Data, expectedSize: Int) throws -> Data {
        var bufferSize = max(expectedSize * 2, max(compressed.count * 8, 4096))
        let maxBufferSize = 64 * 1024 * 1024
        var attempt = 0
        while attempt < 6 {
            var output = Data(count: bufferSize)
            let written: Int = output.withUnsafeMutableBytes { destBuf -> Int in
                compressed.withUnsafeBytes { srcBuf -> Int in
                    guard let dst = destBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let src = srcBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                    else { return 0 }
                    return compression_decode_buffer(
                        dst, bufferSize,
                        src, compressed.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            if written > 0 && written < bufferSize {
                output.removeSubrange(written..<output.count)
                return output
            }
            if written == 0 && bufferSize >= max(expectedSize * 4, 1 << 20) {
                throw EpubParserError.decompressionFailed
            }
            if bufferSize >= maxBufferSize {
                throw EpubParserError.decompressionFailed
            }
            bufferSize = min(bufferSize * 2, maxBufferSize)
            attempt += 1
        }
        throw EpubParserError.decompressionFailed
    }
}

// MARK: - XHTML body → ReadableItem extractor

private enum EpubHTMLExtractor {
    private enum BlockType {
        case paragraph
        case title
        case blockquote
        case code
    }

    static func extractItems(from xhtml: String) -> [ScrollTextView.ReadableItem] {
        let body = extractBody(xhtml)
        let cleaned = stripScriptsAndStyles(body)

        var items: [ScrollTextView.ReadableItem] = []
        var buffer = ""
        var currentType: BlockType = .paragraph

        func flush() {
            let collapsed = collapseWhitespace(buffer)
            let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = ""
            guard !trimmed.isEmpty else { return }
            let decoded = decodeEntities(trimmed)
            switch currentType {
            case .title: items.append(.title(decoded))
            case .paragraph: items.append(.paragraph(decoded))
            case .blockquote: items.append(.blockquote(decoded))
            case .code: items.append(.code(decoded))
            }
        }

        let chars = Array(cleaned)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "<" {
                var tagEnd = i + 1
                while tagEnd < chars.count && chars[tagEnd] != ">" { tagEnd += 1 }
                if tagEnd >= chars.count { break }
                let raw = String(chars[(i + 1)..<tagEnd])
                i = tagEnd + 1

                if raw.hasPrefix("!") || raw.hasPrefix("?") { continue }

                let isClose = raw.hasPrefix("/")
                let nameRaw = isClose ? String(raw.dropFirst()) : raw
                let nameEndIdx = nameRaw.firstIndex(where: { $0.isWhitespace || $0 == "/" }) ?? nameRaw.endIndex
                let tagName = nameRaw[nameRaw.startIndex..<nameEndIdx].lowercased()

                switch tagName {
                case "h1", "h2", "h3", "h4", "h5", "h6":
                    flush()
                    currentType = isClose ? .paragraph : .title
                case "p", "div":
                    flush()
                    if isClose { currentType = .paragraph }
                case "blockquote":
                    flush()
                    currentType = isClose ? .paragraph : .blockquote
                case "pre", "code":
                    flush()
                    currentType = isClose ? .paragraph : .code
                case "br", "hr":
                    flush()
                case "li":
                    flush()
                    if !isClose && !buffer.isEmpty { buffer.append("\n") }
                default:
                    break
                }
            } else {
                buffer.append(c)
                i += 1
            }
        }
        flush()

        return items
    }

    private static func extractBody(_ html: String) -> String {
        if let openRange = html.range(of: "<body", options: .caseInsensitive),
           let openTagEnd = html.range(of: ">", range: openRange.upperBound..<html.endIndex),
           let closeRange = html.range(of: "</body>", options: .caseInsensitive, range: openTagEnd.upperBound..<html.endIndex) {
            return String(html[openTagEnd.upperBound..<closeRange.lowerBound])
        }
        return html
    }

    private static func stripScriptsAndStyles(_ html: String) -> String {
        var result = html
        for tag in ["script", "style", "head"] {
            let pattern = "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>"
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    private static func collapseWhitespace(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        var lastWasSpace = false
        for c in s {
            if c.isWhitespace {
                if !lastWasSpace {
                    result.append(" ")
                    lastWasSpace = true
                }
            } else {
                result.append(c)
                lastWasSpace = false
            }
        }
        return result
    }

    private static let namedEntities: [String: String] = [
        "&nbsp;": "\u{00A0}",
        "&amp;": "&",
        "&lt;": "<",
        "&gt;": ">",
        "&quot;": "\"",
        "&apos;": "'",
        "&mdash;": "\u{2014}",
        "&ndash;": "\u{2013}",
        "&hellip;": "\u{2026}",
        "&ldquo;": "\u{201C}",
        "&rdquo;": "\u{201D}",
        "&lsquo;": "\u{2018}",
        "&rsquo;": "\u{2019}",
        "&laquo;": "\u{00AB}",
        "&raquo;": "\u{00BB}",
        "&copy;": "\u{00A9}",
        "&reg;": "\u{00AE}",
        "&trade;": "\u{2122}",
        "&middot;": "\u{00B7}",
        "&bull;": "\u{2022}"
    ]

    private static func decodeEntities(_ s: String) -> String {
        var result = s
        for (entity, replacement) in namedEntities {
            if result.contains(entity) {
                result = result.replacingOccurrences(of: entity, with: replacement)
            }
        }
        guard result.contains("&#") else { return result }

        let pattern = "&#(x[0-9a-fA-F]+|X[0-9a-fA-F]+|[0-9]+);"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let nsString = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else { return result }

        let mutable = NSMutableString(string: result)
        for match in matches.reversed() {
            let codeStr = nsString.substring(with: match.range(at: 1))
            let value: UInt32?
            if codeStr.hasPrefix("x") || codeStr.hasPrefix("X") {
                value = UInt32(codeStr.dropFirst(), radix: 16)
            } else {
                value = UInt32(codeStr)
            }
            if let v = value, let scalar = Unicode.Scalar(v) {
                mutable.replaceCharacters(in: match.range, with: String(Character(scalar)))
            }
        }
        return mutable as String
    }
}
