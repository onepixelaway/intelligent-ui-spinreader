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
