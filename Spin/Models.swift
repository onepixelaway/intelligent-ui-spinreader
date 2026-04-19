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

struct Article: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var feedID: UUID
    var title: String
    var author: String?
    var category: String?
    var publishedDate: Date?
    var link: URL?
    var body: String
}
