import Foundation

enum FeedError: LocalizedError {
    case invalidURL
    case duplicate
    case httpError(Int)
    case parseFailed
    case noItems

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .duplicate: return "Feed already added"
        case .httpError(let code): return "Server returned \(code)"
        case .parseFailed: return "Couldn’t read RSS / Atom feed"
        case .noItems: return "Feed has no items"
        }
    }
}

@MainActor
final class FeedStore: ObservableObject {
    @Published private(set) var feeds: [Feed] = []
    @Published private(set) var articlesByFeed: [UUID: [Article]] = [:]
    @Published private(set) var isRefreshing: Bool = false

    private let feedsKey = "spin.feeds.v1"
    private let articlesKey = "spin.articles.v3"

    init() {
        loadFeeds()
        loadArticles()
    }

    func addFeed(rawURL: String) async throws {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" else {
            throw FeedError.invalidURL
        }
        if feeds.contains(where: { $0.url == url }) { throw FeedError.duplicate }

        let parsed = try await fetchFeed(url: url)
        let resolvedTitle: String = {
            let candidate = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty { return candidate }
            return url.host ?? url.absoluteString
        }()

        let feed = Feed(url: url, title: resolvedTitle)
        feeds.append(feed)
        articlesByFeed[feed.id] = makeArticles(from: parsed, feedID: feed.id)
        saveFeeds()
        saveArticles()
    }

    func removeFeeds(at indexSet: IndexSet) {
        let removed = indexSet.map { feeds[$0] }
        feeds.remove(atOffsets: indexSet)
        for feed in removed {
            articlesByFeed.removeValue(forKey: feed.id)
        }
        saveFeeds()
        saveArticles()
    }

    func refresh() async {
        guard !feeds.isEmpty else { return }
        isRefreshing = true
        let snapshot = feeds.map { ($0.id, $0.url) }

        let updates = await withTaskGroup(of: (UUID, [Article]?).self) { group -> [(UUID, [Article])] in
            for (id, url) in snapshot {
                group.addTask {
                    do {
                        let parsed = try await fetchFeed(url: url)
                        return (id, makeArticles(from: parsed, feedID: id))
                    } catch {
                        return (id, nil)
                    }
                }
            }
            var collected: [(UUID, [Article])] = []
            for await (id, articles) in group {
                if let articles { collected.append((id, articles)) }
            }
            return collected
        }

        for (id, articles) in updates {
            articlesByFeed[id] = articles
        }
        saveArticles()
        isRefreshing = false
    }

    private func loadFeeds() {
        guard let data = UserDefaults.standard.data(forKey: feedsKey),
              let decoded = try? JSONDecoder().decode([Feed].self, from: data) else { return }
        feeds = decoded
    }

    private func saveFeeds() {
        guard let data = try? JSONEncoder().encode(feeds) else { return }
        UserDefaults.standard.set(data, forKey: feedsKey)
    }

    private func loadArticles() {
        guard let data = UserDefaults.standard.data(forKey: articlesKey),
              let decoded = try? JSONDecoder().decode([String: [Article]].self, from: data) else { return }
        var result: [UUID: [Article]] = [:]
        for (key, value) in decoded {
            if let uuid = UUID(uuidString: key) { result[uuid] = value }
        }
        articlesByFeed = result
    }

    private func saveArticles() {
        let stringKeyed = Dictionary(
            uniqueKeysWithValues: articlesByFeed.map { ($0.key.uuidString, $0.value) }
        )
        guard let data = try? JSONEncoder().encode(stringKeyed) else { return }
        UserDefaults.standard.set(data, forKey: articlesKey)
    }
}

private func fetchFeed(url: URL) async throws -> RSSParser.ParsedFeed {
    var request = URLRequest(url: url)
    request.setValue("Spin Reader/1.0", forHTTPHeaderField: "User-Agent")
    request.setValue(
        "application/rss+xml, application/atom+xml, application/xml;q=0.9, */*;q=0.8",
        forHTTPHeaderField: "Accept"
    )
    let (data, response) = try await URLSession.shared.data(for: request)
    if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
        throw FeedError.httpError(http.statusCode)
    }
    let parser = RSSParser()
    guard let parsed = parser.parse(data: data) else { throw FeedError.parseFailed }
    if parsed.items.isEmpty { throw FeedError.noItems }
    return parsed
}

private func makeArticles(from parsed: RSSParser.ParsedFeed, feedID: UUID) -> [Article] {
    parsed.items.enumerated().map { offset, item in
        let rawBody = !item.content.isEmpty ? item.content : item.description
        var blocks = parseContentBlocks(rawBody)

        let hasInlineImage = blocks.contains {
            if case .image = $0 { return true }
            return false
        }
        if !hasInlineImage,
           let heroRaw = item.mediaContent,
           let heroURL = URL(string: heroRaw) {
            blocks.insert(.image(url: heroURL, alt: nil, caption: nil), at: 0)
        }

        let link = item.link.flatMap { URL(string: $0) }
        let identifier: String = {
            if let guid = item.guid, !guid.isEmpty { return guid }
            if let link = item.link, !link.isEmpty { return link }
            return "\(feedID.uuidString)-\(offset)-\(item.title)"
        }()
        return Article(
            id: identifier,
            feedID: feedID,
            title: item.title.trimmingCharacters(in: .whitespacesAndNewlines),
            author: item.author?.trimmingCharacters(in: .whitespacesAndNewlines),
            category: item.category?.trimmingCharacters(in: .whitespacesAndNewlines),
            publishedDate: parseFeedDate(item.pubDate),
            link: link,
            blocks: blocks
        )
    }
}
