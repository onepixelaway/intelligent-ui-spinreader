import Foundation

struct WebArticle: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    let title: String
    let author: String
    let sourceURL: URL?
    let savedAt: Date
    let items: [ScrollTextView.ReadableItem]

    static func == (lhs: WebArticle, rhs: WebArticle) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    func asChapter() -> EpubChapter {
        EpubChapter(
            id: 0,
            title: title,
            xhtmlPath: "article-\(id.uuidString)",
            anchor: nil,
            depth: 0,
            items: items
        )
    }
}

@MainActor
final class WebArticleStore: ObservableObject {
    @Published private(set) var articles: [WebArticle] = []

    private let directory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SpinReader", isDirectory: true)
            .appendingPathComponent("articles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func loadFromDisk() async {
        let dir = directory
        let loaded: [WebArticle] = await Task.detached {
            let fm = FileManager.default
            guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                return []
            }
            let jsonURLs = urls.filter { $0.pathExtension.lowercased() == "json" }
            return await withTaskGroup(of: WebArticle?.self) { group in
                for url in jsonURLs {
                    group.addTask {
                        guard let data = try? Data(contentsOf: url),
                              let article = try? makeArticleDecoder().decode(WebArticle.self, from: data) else {
                            return nil
                        }
                        return article
                    }
                }
                var result: [WebArticle] = []
                result.reserveCapacity(jsonURLs.count)
                for await article in group {
                    if let article { result.append(article) }
                }
                return result
            }
        }.value
        articles = loaded.sorted(by: byRecency)
    }

    func save(_ article: WebArticle) async throws {
        let dir = directory
        try await Task.detached {
            let encoder = makeArticleEncoder()
            let data = try encoder.encode(article)
            let url = dir.appendingPathComponent("\(article.id.uuidString).json")
            try data.write(to: url, options: .atomic)
        }.value
        if let idx = articles.firstIndex(where: { $0.id == article.id }) {
            articles[idx] = article
        } else {
            articles.append(article)
        }
        articles.sort(by: byRecency)
    }

    func delete(_ article: WebArticle) {
        let url = directory.appendingPathComponent("\(article.id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
        articles.removeAll { $0.id == article.id }
    }
}

private func byRecency(_ a: WebArticle, _ b: WebArticle) -> Bool { a.savedAt > b.savedAt }

private func makeArticleDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

private func makeArticleEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

extension ScrollTextView.FootnoteRef: Codable {
    private enum CodingKeys: String, CodingKey { case marker, content }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            marker: try c.decode(String.self, forKey: .marker),
            content: try c.decode(String.self, forKey: .content)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(marker, forKey: .marker)
        try c.encode(content, forKey: .content)
    }
}

extension ScrollTextView.ReadableItem: Codable {
    private enum Kind: String, Codable {
        case title, byline, paragraph, subheading, listItem, image, blockquote, code
        case divider, callout, paragraphWithFootnotes, chapterTOC
    }

    private enum CodingKeys: String, CodingKey {
        case kind, text, ordered, index, url, alt, caption, footnotes, items
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .title:
            self = .title(try c.decode(String.self, forKey: .text))
        case .byline:
            self = .byline(try c.decode(String.self, forKey: .text))
        case .paragraph:
            self = .paragraph(try c.decode(String.self, forKey: .text))
        case .subheading:
            self = .subheading(try c.decode(String.self, forKey: .text))
        case .listItem:
            self = .listItem(
                try c.decode(String.self, forKey: .text),
                ordered: try c.decode(Bool.self, forKey: .ordered),
                index: try c.decode(Int.self, forKey: .index)
            )
        case .image:
            self = .image(
                url: try c.decode(URL.self, forKey: .url),
                alt: try c.decodeIfPresent(String.self, forKey: .alt),
                caption: try c.decodeIfPresent(String.self, forKey: .caption)
            )
        case .blockquote:
            self = .blockquote(try c.decode(String.self, forKey: .text))
        case .code:
            self = .code(try c.decode(String.self, forKey: .text))
        case .divider:
            self = .divider
        case .callout:
            self = .callout(try c.decode(String.self, forKey: .text))
        case .paragraphWithFootnotes:
            self = .paragraphWithFootnotes(
                text: try c.decode(String.self, forKey: .text),
                footnotes: try c.decode([ScrollTextView.FootnoteRef].self, forKey: .footnotes)
            )
        case .chapterTOC:
            self = .chapterTOC(try c.decode([String].self, forKey: .items))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .title(let t):
            try c.encode(Kind.title, forKey: .kind)
            try c.encode(t, forKey: .text)
        case .byline(let t):
            try c.encode(Kind.byline, forKey: .kind)
            try c.encode(t, forKey: .text)
        case .paragraph(let t):
            try c.encode(Kind.paragraph, forKey: .kind)
            try c.encode(t, forKey: .text)
        case .richParagraph(let rich):
            // Rich formatting can't survive JSON cleanly; persist as plain paragraph.
            try c.encode(Kind.paragraph, forKey: .kind)
            try c.encode(rich.attributedString.string, forKey: .text)
        case .subheading(let t):
            try c.encode(Kind.subheading, forKey: .kind)
            try c.encode(t, forKey: .text)
        case .listItem(let t, let ordered, let idx):
            try c.encode(Kind.listItem, forKey: .kind)
            try c.encode(t, forKey: .text)
            try c.encode(ordered, forKey: .ordered)
            try c.encode(idx, forKey: .index)
        case .image(let url, let alt, let caption):
            try c.encode(Kind.image, forKey: .kind)
            try c.encode(url, forKey: .url)
            try c.encodeIfPresent(alt, forKey: .alt)
            try c.encodeIfPresent(caption, forKey: .caption)
        case .blockquote(let t):
            try c.encode(Kind.blockquote, forKey: .kind)
            try c.encode(t, forKey: .text)
        case .code(let t):
            try c.encode(Kind.code, forKey: .kind)
            try c.encode(t, forKey: .text)
        case .divider:
            try c.encode(Kind.divider, forKey: .kind)
        case .callout(let t):
            try c.encode(Kind.callout, forKey: .kind)
            try c.encode(t, forKey: .text)
        case .paragraphWithFootnotes(let text, let footnotes):
            try c.encode(Kind.paragraphWithFootnotes, forKey: .kind)
            try c.encode(text, forKey: .text)
            try c.encode(footnotes, forKey: .footnotes)
        case .chapterTOC(let items):
            try c.encode(Kind.chapterTOC, forKey: .kind)
            try c.encode(items, forKey: .items)
        }
    }
}
