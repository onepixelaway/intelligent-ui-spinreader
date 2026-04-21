import Foundation
import Observation

struct Feed: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var url: URL
    var title: String

    init(id: UUID = UUID(), url: URL, title: String) {
        self.id = id
        self.url = url
        self.title = title
    }
}

enum ContentBlock: Codable, Hashable, Sendable {
    case text(String)
    case image(url: URL, alt: String?, caption: String?)
    case blockquote(String)
    case code(String)
    case video(videoURL: URL, thumbnailURL: URL?, provider: VideoProvider)
}

enum VideoProvider: String, Codable, Hashable, Sendable {
    case youtube
    case vimeo
}

struct Article: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var feedID: UUID
    var title: String
    var author: String?
    var category: String?
    var publishedDate: Date?
    var link: URL?
    var blocks: [ContentBlock]

    var heroImageURL: URL? {
        for block in blocks {
            if case .image(let url, _, _) = block { return url }
            if case .video(_, let thumbnail, _) = block, let thumbnail { return thumbnail }
        }
        return nil
    }
}

struct Highlight: Identifiable, Codable {
    var id: UUID
    var contentID: String
    var text: String
    var startOffset: Int
    var endOffset: Int
    var color: String
    var createdAt: Date

    init(id: UUID = UUID(), contentID: String, text: String, startOffset: Int, endOffset: Int, color: String = "yellow", createdAt: Date = Date()) {
        self.id = id
        self.contentID = contentID
        self.text = text
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.color = color
        self.createdAt = createdAt
    }
}

@Observable
@MainActor
final class HighlightStore {
    private(set) var highlights: [Highlight] = []
    private var highlightsByContentID: [String: [Highlight]] = [:]
    private var pendingSaveTask: Task<Void, Never>?

    private static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SpinReader", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("highlights.json")
    }

    init() {
        load()
    }

    func highlights(for contentID: String) -> [Highlight] {
        highlightsByContentID[contentID] ?? []
    }

    func add(_ highlight: Highlight) {
        highlights.append(highlight)
        highlightsByContentID[highlight.contentID, default: []].append(highlight)
        debouncedSave()
    }

    func addBatch(_ newHighlights: [Highlight]) {
        guard !newHighlights.isEmpty else { return }
        highlights.append(contentsOf: newHighlights)
        for h in newHighlights {
            highlightsByContentID[h.contentID, default: []].append(h)
        }
        debouncedSave()
    }

    func remove(id: UUID) {
        guard let h = highlights.first(where: { $0.id == id }) else { return }
        highlightsByContentID[h.contentID]?.removeAll { $0.id == id }
        highlights.removeAll { $0.id == id }
        debouncedSave()
    }

    func removeBatch(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let removed = highlights.filter { ids.contains($0.id) }
        for h in removed {
            highlightsByContentID[h.contentID]?.removeAll { $0.id == h.id }
        }
        highlights.removeAll { ids.contains($0.id) }
        debouncedSave()
    }

    private func rebuildIndex() {
        highlightsByContentID = Dictionary(grouping: highlights, by: \.contentID)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([Highlight].self, from: data) else { return }
        highlights = decoded
        rebuildIndex()
    }

    private func debouncedSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(highlights) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
