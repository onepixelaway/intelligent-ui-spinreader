import Foundation
import UIKit
import Compression

struct EpubBook: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let author: String
    let chapters: [EpubChapter]
    let fileURL: URL
    let coverImageData: Data?

    static func == (lhs: EpubBook, rhs: EpubBook) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct EpubChapter: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let xhtmlPath: String
    let anchor: String?
    let depth: Int
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

        let bookTitle = opf.title.isEmpty ? fileURL.deletingPathExtension().lastPathComponent : opf.title

        let tocEntries = parseTOC(archive: archive, opf: opf, opfBase: opfBase)

        var itemsCache: [String: [ScrollTextView.ReadableItem]] = [:]
        func itemsForXHTML(_ xhtmlPath: String) -> [ScrollTextView.ReadableItem]? {
            if let cached = itemsCache[xhtmlPath] { return cached }
            guard let chapterData = try? archive.fileData(named: xhtmlPath),
                  let xhtml = String(data: chapterData, encoding: .utf8)
                          ?? String(data: chapterData, encoding: .isoLatin1)
            else { return nil }
            let parsed = EpubHTMLExtractor.extractItems(
                from: xhtml,
                xhtmlPath: xhtmlPath,
                bookTitle: bookTitle,
                imageExtractor: { path in try? archive.fileData(named: path) }
            )
            itemsCache[xhtmlPath] = parsed
            return parsed
        }

        var chapters: [EpubChapter] = []
        for entry in tocEntries {
            let decodedHref = entry.href.removingPercentEncoding ?? entry.href
            let (file, fragment) = splitFragment(decodedHref)
            let xhtmlPath = normalize(entry.basePath + file)
            guard let items = itemsForXHTML(xhtmlPath) else { continue }
            chapters.append(EpubChapter(
                id: chapters.count,
                title: entry.title,
                xhtmlPath: xhtmlPath,
                anchor: fragment,
                depth: entry.depth,
                items: items
            ))
        }

        if chapters.isEmpty {
            for itemId in opf.spineIDs {
                guard let href = opf.manifestById[itemId] else { continue }
                let decodedHref = href.removingPercentEncoding ?? href
                let xhtmlPath = normalize(opfBase + decodedHref)
                guard let items = itemsForXHTML(xhtmlPath), !items.isEmpty else { continue }
                let title: String = {
                    if case .title(let t) = items.first { return t }
                    return "Chapter \(chapters.count + 1)"
                }()
                chapters.append(EpubChapter(
                    id: chapters.count,
                    title: title,
                    xhtmlPath: xhtmlPath,
                    anchor: nil,
                    depth: 0,
                    items: items
                ))
            }
        }

        let title = bookTitle
        let coverData = extractCoverImage(opf: opf, opfBase: opfBase, archive: archive)

        if let coverData = coverData {
            let fm = FileManager.default
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            let coverDir = docs.appendingPathComponent("epubs", isDirectory: true)
            try? fm.createDirectory(at: coverDir, withIntermediateDirectories: true)
            let safeName = fileURL.deletingPathExtension().lastPathComponent
            let coverFile = coverDir.appendingPathComponent("\(safeName)_cover.jpg")
            try? coverData.write(to: coverFile)
        }

        return EpubBook(
            id: fileURL.lastPathComponent,
            title: title,
            author: opf.author,
            chapters: chapters,
            fileURL: fileURL,
            coverImageData: coverData
        )
    }

    private static func extractCoverImage(opf: OPFContents, opfBase: String, archive: ZipArchive) -> Data? {
        let imageTypes = Set(["image/jpeg", "image/png", "image/gif", "image/svg+xml"])

        func resolve(_ itemId: String) -> Data? {
            guard let href = opf.manifestById[itemId] else { return nil }
            let decodedHref = href.removingPercentEncoding ?? href
            let fullPath = normalize(opfBase + decodedHref)
            return try? archive.fileData(named: fullPath)
        }

        if let coverId = opf.coverMetaContent, resolve(coverId) != nil {
            return resolve(coverId)
        }

        for (id, props) in opf.manifestProperties {
            if props.contains("cover-image"), resolve(id) != nil {
                return resolve(id)
            }
        }

        for candidateId in ["cover", "cover-image", "coverimage"] {
            if let mediaType = opf.manifestMediaTypes[candidateId],
               imageTypes.contains(mediaType),
               let data = resolve(candidateId) {
                return data
            }
        }

        return nil
    }

    fileprivate static func normalize(_ path: String) -> String {
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
            manifestMediaTypes: delegate.manifestMediaTypes,
            manifestProperties: delegate.manifestProperties,
            spineIDs: delegate.spineIDs,
            navHref: delegate.navHref,
            ncxHref: delegate.ncxHref,
            coverMetaContent: delegate.coverMetaContent
        )
    }

    private static func parseTOC(archive: ZipArchive, opf: OPFContents, opfBase: String) -> [TOCEntry] {
        if let ncxHref = opf.ncxHref {
            let fullPath = normalize(opfBase + ncxHref)
            if let data = try? archive.fileData(named: fullPath) {
                let entries = parseNCX(data, basePath: directory(of: fullPath))
                if !entries.isEmpty { return entries }
            }
        }
        if let navHref = opf.navHref {
            let fullPath = normalize(opfBase + navHref)
            if let data = try? archive.fileData(named: fullPath),
               let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                let entries = parseNavDocument(html, basePath: directory(of: fullPath))
                if !entries.isEmpty { return entries }
            }
        }
        return []
    }

    private static func parseNavDocument(_ html: String, basePath: String) -> [TOCEntry] {
        guard let data = html.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        let delegate = NavDocParserDelegate(basePath: basePath)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.parse()
        return delegate.entries
    }

    private static func parseNCX(_ data: Data, basePath: String) -> [TOCEntry] {
        let parser = XMLParser(data: data)
        let delegate = NCXParserDelegate(basePath: basePath)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.parse()
        return delegate.entries
    }

    fileprivate static func splitFragment(_ href: String) -> (file: String, fragment: String?) {
        if let hashIndex = href.firstIndex(of: "#") {
            let file = String(href[href.startIndex..<hashIndex])
            let frag = String(href[href.index(after: hashIndex)...])
            return (file, frag.isEmpty ? nil : frag)
        }
        return (href, nil)
    }

    fileprivate static func directory(of path: String) -> String {
        if let lastSlash = path.lastIndex(of: "/") {
            return String(path[path.startIndex...lastSlash])
        }
        return ""
    }
}

private struct OPFContents {
    let title: String
    let author: String
    let manifestById: [String: String]
    let manifestMediaTypes: [String: String]
    let manifestProperties: [String: String]
    let spineIDs: [String]
    let navHref: String?
    let ncxHref: String?
    let coverMetaContent: String?
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
    var manifestMediaTypes: [String: String] = [:]
    var manifestProperties: [String: String] = [:]
    var spineIDs: [String] = []
    var navHref: String?
    var ncxHref: String?
    var coverMetaContent: String?

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
            if let mediaType = attributeDict["media-type"] {
                manifestMediaTypes[id] = mediaType
            }
            if let props = attributeDict["properties"] {
                manifestProperties[id] = props
                if props.contains("nav") {
                    navHref = href
                }
            }
            if attributeDict["media-type"] == "application/x-dtbncx+xml" {
                ncxHref = href
            }
        }
        if elementName == "itemref", let idref = attributeDict["idref"] {
            spineIDs.append(idref)
        }
        if elementName == "meta",
           attributeDict["name"] == "cover",
           let content = attributeDict["content"] {
            coverMetaContent = content
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

// MARK: - TOC Parsers

private struct TOCEntry {
    let href: String
    let title: String
    let depth: Int
    let basePath: String
}

private final class NavDocParserDelegate: NSObject, XMLParserDelegate {
    var entries: [TOCEntry] = []
    private let basePath: String
    private var inTocNav = false
    private var currentHref: String?
    private var buffer: String = ""
    private var inAnchor = false
    private var olDepth = 0

    init(basePath: String) {
        self.basePath = basePath
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "nav" {
            let epubType = attributeDict["epub:type"] ?? attributeDict["type"] ?? ""
            if epubType.contains("toc") {
                inTocNav = true
            }
        }
        if inTocNav {
            if elementName == "ol" { olDepth += 1 }
            if elementName == "a" {
                inAnchor = true
                currentHref = attributeDict["href"]
                buffer = ""
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inAnchor { buffer += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if inTocNav {
            if elementName == "a", let href = currentHref {
                let title = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    entries.append(TOCEntry(
                        href: href,
                        title: title,
                        depth: max(0, olDepth - 1),
                        basePath: basePath
                    ))
                }
                inAnchor = false
                currentHref = nil
            }
            if elementName == "ol" { olDepth = max(0, olDepth - 1) }
            if elementName == "nav" { inTocNav = false }
        }
    }
}

private final class NCXParserDelegate: NSObject, XMLParserDelegate {
    var entries: [TOCEntry] = []
    private let basePath: String

    private struct PendingNavPoint {
        var entryIndex: Int
        var titleSet: Bool
        var srcSet: Bool
    }
    private var stack: [PendingNavPoint] = []
    private var inText = false
    private var buffer: String = ""

    init(basePath: String) {
        self.basePath = basePath
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "navPoint" {
            entries.append(TOCEntry(href: "", title: "", depth: stack.count, basePath: basePath))
            stack.append(PendingNavPoint(entryIndex: entries.count - 1, titleSet: false, srcSet: false))
            return
        }
        guard !stack.isEmpty else { return }
        if elementName == "text" {
            inText = true
            buffer = ""
        } else if elementName == "content", let src = attributeDict["src"] {
            let top = stack.count - 1
            if !stack[top].srcSet {
                let existing = entries[stack[top].entryIndex]
                entries[stack[top].entryIndex] = TOCEntry(
                    href: src,
                    title: existing.title,
                    depth: existing.depth,
                    basePath: existing.basePath
                )
                stack[top].srcSet = true
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { buffer += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "text" {
            inText = false
            if !stack.isEmpty {
                let top = stack.count - 1
                if !stack[top].titleSet {
                    let title = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty {
                        let existing = entries[stack[top].entryIndex]
                        entries[stack[top].entryIndex] = TOCEntry(
                            href: existing.href,
                            title: title,
                            depth: existing.depth,
                            basePath: existing.basePath
                        )
                        stack[top].titleSet = true
                    }
                }
            }
            buffer = ""
        } else if elementName == "navPoint" {
            if !stack.isEmpty { stack.removeLast() }
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        entries = entries.filter { !$0.href.isEmpty && !$0.title.isEmpty }
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
        case subheading
        case blockquote
        case code
    }

    private struct TextSpan {
        let text: String
        let bold: Bool
        let italic: Bool
    }

    private static let sceneBreakPatterns: Set<String> = ["* * *", "***", "---", "· · ·", "⁂"]

    private static let calloutKeywords = ["callout", "pull-quote", "pullquote", "sidebar", "note", "tip", "warning", "admonition", "aside"]

    private static let footnoteOpenRegexes: [(regex: NSRegularExpression, close: String)] = {
        let patterns: [(open: String, close: String)] = [
            ("<aside[^>]*epub:type\\s*=\\s*[\"'][^\"']*footnote[^\"']*[\"'][^>]*>", "</aside>"),
            ("<aside[^>]*epub:type\\s*=\\s*[\"'][^\"']*endnote[^\"']*[\"'][^>]*>", "</aside>"),
            ("<div[^>]*class\\s*=\\s*[\"'][^\"']*footnote[^\"']*[\"'][^>]*>", "</div>"),
            ("<section[^>]*epub:type\\s*=\\s*[\"'][^\"']*footnotes[^\"']*[\"'][^>]*>", "</section>"),
            ("<section[^>]*epub:type\\s*=\\s*[\"'][^\"']*endnotes[^\"']*[\"'][^>]*>", "</section>"),
        ]
        return patterns.compactMap { p in
            (try? NSRegularExpression(pattern: p.open, options: [.caseInsensitive, .dotMatchesLineSeparators])).map { ($0, p.close) }
        }
    }()
    private static let idRegex = try! NSRegularExpression(pattern: "id\\s*=\\s*[\"']([^\"']+)[\"']", options: .caseInsensitive)
    private static let tagStripRegex = try! NSRegularExpression(pattern: "<[^>]+>")
    private static let liFootnoteRegex = try! NSRegularExpression(pattern: "<li[^>]*id\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>", options: .caseInsensitive)

    private static let fontRegular: UIFont = UIFont.systemFont(ofSize: 17)
    private static let fontBold: UIFont = {
        let desc = UIFont.systemFont(ofSize: 17).fontDescriptor
        return UIFont(descriptor: desc.withSymbolicTraits(.traitBold) ?? desc, size: 17)
    }()
    private static let fontItalic: UIFont = {
        let desc = UIFont.systemFont(ofSize: 17).fontDescriptor
        return UIFont(descriptor: desc.withSymbolicTraits(.traitItalic) ?? desc, size: 17)
    }()
    private static let fontBoldItalic: UIFont = {
        let desc = UIFont.systemFont(ofSize: 17).fontDescriptor
        return UIFont(descriptor: desc.withSymbolicTraits([.traitBold, .traitItalic]) ?? desc, size: 17)
    }()

    static func extractItems(
        from xhtml: String,
        xhtmlPath: String = "",
        bookTitle: String = "",
        imageExtractor: ((String) -> Data?)? = nil
    ) -> [ScrollTextView.ReadableItem] {
        let footnoteContent = collectFootnotes(from: xhtml)
        let body = extractBody(xhtml)
        let cleaned = stripScriptsAndStyles(body)

        let xhtmlDir: String = {
            if let lastSlash = xhtmlPath.lastIndex(of: "/") {
                return String(xhtmlPath[...lastSlash])
            }
            return ""
        }()

        let imageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spinreader-epub-images")
            .appendingPathComponent(bookTitle)
        if imageExtractor != nil {
            try? FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)
        }

        var items: [ScrollTextView.ReadableItem] = []
        var spans: [TextSpan] = []
        var textBuffer = ""
        var currentType: BlockType = .paragraph
        var boldDepth = 0
        var italicDepth = 0
        var hasFormatting = false
        var hadFirstHeading = false
        var blockquoteDepth = 0
        var isCallout = false

        var listStack: [(ordered: Bool, index: Int)] = []
        var pendingFootnotes: [ScrollTextView.FootnoteRef] = []
        var footnoteCounter = 0
        var insideFootnoteAnchor = false

        var inFigure = false
        var inFigcaption = false
        var pendingFigureImage: (url: URL, alt: String?)?
        var figcaptionBuffer = ""
        var figcaptionParts: [String] = []

        let sceneBreakPatterns = Self.sceneBreakPatterns

        func flushTextBuffer() {
            if !textBuffer.isEmpty {
                spans.append(TextSpan(text: textBuffer, bold: boldDepth > 0, italic: italicDepth > 0))
                textBuffer = ""
            }
        }

        func finishFigcaptionPart() {
            let trimmed = collapseWhitespace(decodeEntities(figcaptionBuffer)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { figcaptionParts.append(trimmed) }
            figcaptionBuffer = ""
        }

        func flush() {
            flushTextBuffer()

            let fullText = spans.map(\.text).joined()
            let collapsed = collapseWhitespace(fullText)
            let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)

            defer {
                spans = []
                hasFormatting = false
                pendingFootnotes = []
            }

            guard !trimmed.isEmpty else { return }

            if currentType == .title || currentType == .subheading {
                let decoded = decodeEntities(trimmed)
                if !hadFirstHeading {
                    hadFirstHeading = true
                    items.append(.title(decoded))
                } else {
                    items.append(.subheading(decoded))
                }
                return
            }

            if !listStack.isEmpty, let last = listStack.last {
                let decoded = decodeEntities(trimmed)
                items.append(.listItem(decoded, ordered: last.ordered, index: last.index))
                return
            }

            if sceneBreakPatterns.contains(trimmed) {
                items.append(.divider)
                return
            }

            if isCallout || blockquoteDepth > 1 {
                let decoded = decodeEntities(trimmed)
                items.append(.callout(decoded))
                return
            }

            if !pendingFootnotes.isEmpty && currentType == .paragraph && !hasFormatting {
                let decoded = decodeEntities(trimmed)
                items.append(.paragraphWithFootnotes(text: decoded, footnotes: pendingFootnotes))
            } else if hasFormatting {
                let attrStr = buildAttributedString(from: spans)
                items.append(.richParagraph(ScrollTextView.RichText(attributedString: attrStr)))
            } else {
                let decoded = decodeEntities(trimmed)
                switch currentType {
                case .paragraph: items.append(.paragraph(decoded))
                case .blockquote: items.append(.blockquote(decoded))
                case .code: items.append(.code(decoded))
                case .title, .subheading: break
                }
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

                if inFigcaption {
                    switch tagName {
                    case "figcaption":
                        if isClose {
                            finishFigcaptionPart()
                            inFigcaption = false
                        }
                    case "p", "div":
                        finishFigcaptionPart()
                    case "br":
                        if !figcaptionBuffer.isEmpty, !figcaptionBuffer.hasSuffix(" ") {
                            figcaptionBuffer.append(" ")
                        }
                    default:
                        break
                    }
                    continue
                }

                switch tagName {
                case "figure":
                    flush()
                    if !isClose {
                        inFigure = true
                        pendingFigureImage = nil
                        figcaptionParts = []
                        figcaptionBuffer = ""
                    } else {
                        if let pending = pendingFigureImage {
                            let caption = figcaptionParts.joined(separator: "\n")
                            items.append(.image(
                                url: pending.url,
                                alt: pending.alt,
                                caption: caption.isEmpty ? nil : caption
                            ))
                        }
                        inFigure = false
                        pendingFigureImage = nil
                        figcaptionParts = []
                        figcaptionBuffer = ""
                    }
                case "figcaption":
                    if !isClose {
                        flush()
                        inFigcaption = true
                        figcaptionBuffer = ""
                    }
                case "img":
                    if !isClose, let extractor = imageExtractor,
                       let src = extractAttribute("src", from: raw) {
                        flush()
                        let resolvedPath = EpubParser.normalize(xhtmlDir + src)
                        if let imageData = extractor(resolvedPath) {
                            let filename = URL(string: src.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? src)?.lastPathComponent ?? "image.png"
                            let fileURL = imageDir.appendingPathComponent(filename)
                            try? imageData.write(to: fileURL)
                            let alt = extractAttribute("alt", from: raw)
                            if inFigure {
                                pendingFigureImage = (fileURL, alt)
                            } else {
                                items.append(.image(url: fileURL, alt: alt, caption: nil))
                            }
                        }
                    }
                case "h1", "h2", "h3", "h4", "h5", "h6":
                    flush()
                    currentType = isClose ? .paragraph : .title
                case "p", "div":
                    flush()
                    if !isClose {
                        if let cls = extractAttribute("class", from: raw)?.lowercased(),
                           hasCalloutClass(cls) {
                            isCallout = true
                        }
                    } else {
                        currentType = .paragraph
                        isCallout = false
                    }
                case "blockquote":
                    flush()
                    if isClose {
                        blockquoteDepth = max(0, blockquoteDepth - 1)
                        if blockquoteDepth == 0 {
                            currentType = .paragraph
                            isCallout = false
                        }
                    } else {
                        blockquoteDepth += 1
                        currentType = .blockquote
                        if let cls = extractAttribute("class", from: raw)?.lowercased(),
                           hasCalloutClass(cls) {
                            isCallout = true
                        }
                    }
                case "pre", "code":
                    flush()
                    currentType = isClose ? .paragraph : .code
                case "br":
                    flush()
                case "hr":
                    flush()
                    items.append(.divider)
                case "b", "strong":
                    flushTextBuffer()
                    if isClose {
                        boldDepth = max(0, boldDepth - 1)
                    } else {
                        boldDepth += 1
                        hasFormatting = true
                    }
                case "em", "i":
                    flushTextBuffer()
                    if isClose {
                        italicDepth = max(0, italicDepth - 1)
                    } else {
                        italicDepth += 1
                        hasFormatting = true
                    }
                case "ul":
                    flush()
                    if !isClose {
                        listStack.append((ordered: false, index: 0))
                    } else if !listStack.isEmpty {
                        listStack.removeLast()
                    }
                case "ol":
                    flush()
                    if !isClose {
                        listStack.append((ordered: true, index: 0))
                    } else if !listStack.isEmpty {
                        listStack.removeLast()
                    }
                case "li":
                    flush()
                    if !isClose, !listStack.isEmpty {
                        listStack[listStack.count - 1].index += 1
                    }
                case "a":
                    if isClose {
                        insideFootnoteAnchor = false
                    } else if let href = extractAttribute("href", from: raw),
                              href.hasPrefix("#") {
                        let targetID = String(href.dropFirst())
                        if let content = footnoteContent[targetID] {
                            insideFootnoteAnchor = true
                            footnoteCounter += 1
                            let marker = "\(footnoteCounter)"
                            pendingFootnotes.append(ScrollTextView.FootnoteRef(marker: marker, content: content))
                            textBuffer.append("[\(marker)]")
                        }
                    }
                case "aside", "section":
                    if !isClose {
                        let epubType = extractAttribute("epub:type", from: raw)?.lowercased() ?? ""
                        let cls = extractAttribute("class", from: raw)?.lowercased() ?? ""
                        let id = extractAttribute("id", from: raw) ?? ""
                        if epubType.contains("footnote") || epubType.contains("endnote")
                            || cls.contains("footnote") || cls.contains("endnote")
                            || footnoteContent[id] != nil {
                            var depth = 1
                            while i < chars.count && depth > 0 {
                                if chars[i] == "<" {
                                    var te = i + 1
                                    while te < chars.count && chars[te] != ">" { te += 1 }
                                    let inner = String(chars[(i+1)..<min(te, chars.count)])
                                    let innerName = inner.hasPrefix("/") ? String(inner.dropFirst()) : inner
                                    let nameEnd = innerName.firstIndex(where: { $0.isWhitespace || $0 == "/" }) ?? innerName.endIndex
                                    let tn = innerName[innerName.startIndex..<nameEnd].lowercased()
                                    if tn == tagName {
                                        if inner.hasPrefix("/") { depth -= 1 } else { depth += 1 }
                                    }
                                    i = te + 1
                                } else {
                                    i += 1
                                }
                            }
                            continue
                        }
                    }
                default:
                    break
                }
            } else {
                if inFigcaption {
                    figcaptionBuffer.append(c)
                } else if !insideFootnoteAnchor {
                    textBuffer.append(c)
                }
                i += 1
            }
        }
        flush()

        return items
    }

    private static func collectFootnotes(from xhtml: String) -> [String: String] {
        var result: [String: String] = [:]

        for (openRegex, _) in footnoteOpenRegexes {
            let ns = xhtml as NSString
            let matches = openRegex.matches(in: xhtml, range: NSRange(location: 0, length: ns.length))
            for match in matches {
                let openTag = ns.substring(with: match.range)
                guard let idMatch = idRegex.firstMatch(in: openTag, range: NSRange(location: 0, length: openTag.count)),
                      let idRange = Range(idMatch.range(at: 1), in: openTag) else { continue }
                let footnoteID = String(openTag[idRange])

                let afterOpen = match.range.location + match.range.length
                let remaining = ns.substring(from: afterOpen)
                let closingTags = ["</aside>", "</div>", "</section>"]
                var endPos = remaining.count
                for ct in closingTags {
                    if let r = remaining.range(of: ct, options: .caseInsensitive) {
                        let pos = remaining.distance(from: remaining.startIndex, to: r.lowerBound)
                        if pos < endPos { endPos = pos }
                    }
                }
                let innerHTML = String(remaining.prefix(endPos))
                let nsInner = innerHTML as NSString
                let stripped = tagStripRegex.stringByReplacingMatches(in: innerHTML, range: NSRange(location: 0, length: nsInner.length), withTemplate: "")
                let text = decodeEntities(collapseWhitespace(stripped).trimmingCharacters(in: .whitespacesAndNewlines))
                if !text.isEmpty {
                    result[footnoteID] = text
                }
            }
        }

        let ns = xhtml as NSString
        let liMatches = liFootnoteRegex.matches(in: xhtml, range: NSRange(location: 0, length: ns.length))
        for match in liMatches {
            guard let idRange = Range(match.range(at: 1), in: xhtml) else { continue }
            let liID = String(xhtml[idRange])
            if result[liID] != nil { continue }
            let afterOpen = match.range.location + match.range.length
            let remaining = ns.substring(from: afterOpen)
            if let closeRange = remaining.range(of: "</li>", options: .caseInsensitive) {
                let inner = String(remaining[remaining.startIndex..<closeRange.lowerBound])
                let nsInner = inner as NSString
                let stripped = tagStripRegex.stringByReplacingMatches(in: inner, range: NSRange(location: 0, length: nsInner.length), withTemplate: "")
                var text = decodeEntities(collapseWhitespace(stripped).trimmingCharacters(in: .whitespacesAndNewlines))
                text = text.replacingOccurrences(of: "\u{21A9}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    result[liID] = text
                }
            }
        }

        return result
    }

    private static func buildAttributedString(from spans: [TextSpan]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for span in spans {
            let decoded = decodeEntities(span.text)
            let font: UIFont
            switch (span.bold, span.italic) {
            case (true, true): font = fontBoldItalic
            case (true, false): font = fontBold
            case (false, true): font = fontItalic
            case (false, false): font = fontRegular
            }
            result.append(NSAttributedString(string: decoded, attributes: [.font: font]))
        }
        return result
    }

    private static func extractAttribute(_ name: String, from tagContent: String) -> String? {
        guard let nameRange = tagContent.range(of: name, options: .caseInsensitive) else { return nil }
        var i = nameRange.upperBound
        while i < tagContent.endIndex && tagContent[i].isWhitespace { i = tagContent.index(after: i) }
        guard i < tagContent.endIndex, tagContent[i] == "=" else { return nil }
        i = tagContent.index(after: i)
        while i < tagContent.endIndex && tagContent[i].isWhitespace { i = tagContent.index(after: i) }
        guard i < tagContent.endIndex else { return nil }
        let quote = tagContent[i]
        guard quote == "\"" || quote == "'" else { return nil }
        i = tagContent.index(after: i)
        guard let closeQuote = tagContent[i...].firstIndex(of: quote) else { return nil }
        return String(tagContent[i..<closeQuote])
    }

    private static func hasCalloutClass(_ cls: String) -> Bool {
        calloutKeywords.contains(where: { cls.contains($0) })
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
