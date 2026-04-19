import Foundation

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
}
