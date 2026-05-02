import SwiftUI

extension ScrollTextView {
    func textForAnalysis(_ item: ReadableItem) -> String {
        switch item {
        case .title(let text), .byline(let text), .paragraph(let text), .blockquote(let text), .code(let text), .subheading(let text), .callout(let text):
            return text
        case .richParagraph(let rt):
            return rt.attributedString.string
        case .listItem(let text, _, _):
            return text
        case .image(_, let alt, let caption):
            return [alt, caption].compactMap { $0 }.joined(separator: " ")
        case .divider:
            return ""
        case .paragraphWithFootnotes(let text, _):
            return text
        case .chapterTOC(let entries):
            return entries.joined(separator: "\n")
        }
    }

    func advanceToNextChapter() {
        let nextIndex = chapterIndex + 1
        guard !chapters.isEmpty, nextIndex < chapters.count else { return }
        guard !isLoadingNextChapter else { return }
        isLoadingNextChapter = true

        let chapter = chapters[nextIndex]
        var newItems: [ReadableItem] = [.divider]

        let trimmedTitle = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var chapterItems = chapter.items
        if let first = chapterItems.first, case .title = first {
            chapterItems.removeFirst()
        }
        if !trimmedTitle.isEmpty {
            newItems.append(.title(trimmedTitle))
        }
        newItems.append(contentsOf: chapterItems)

        chapterIndex = nextIndex
        items.append(contentsOf: newItems)
        let newContentID = Self.chapterContentID(bookID: bookID ?? "", xhtmlPath: chapter.xhtmlPath)
        itemContentIDs.append(contentsOf: Self.itemContentIDs(for: newItems, chapterContentID: newContentID))

        tags = []
        chapterTags = []
        currentQuestion = ""
        lastAnalyzedText = ""
        lastTaggedText = ""
        spinCount = 0
        seedChapterTags()
    }
}
