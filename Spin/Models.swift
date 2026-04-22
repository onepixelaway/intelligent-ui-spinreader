import Foundation
import Observation

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
        let byContentID = Dictionary(grouping: removed, by: \.contentID)
        for (cid, toRemove) in byContentID {
            let removeIDs = Set(toRemove.map(\.id))
            highlightsByContentID[cid]?.removeAll { removeIDs.contains($0.id) }
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

    // Coalesces burst writes with a 300ms delay. Call flush() on app backgrounding to avoid losing in-flight mutations.
    private func debouncedSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            save()
        }
    }

    func flush() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(highlights) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
