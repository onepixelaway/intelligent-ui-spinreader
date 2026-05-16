import SwiftUI
import NaturalLanguage
@preconcurrency import OpenAI

extension ScrollTextView {
    func visibleTextOnScreen() -> String {
        textForAnalysis(indices: visibleParagraphs)
    }

    func openPerplexity(for action: PanelAction) {
        let visibleText = visibleTextOnScreen()
        guard !visibleText.isEmpty else { return }

        var parts: [String] = [action.prompt, "", visibleText]

        let bookContext = buildBookContext()
        if !bookContext.isEmpty {
            parts.append("")
            parts.append(bookContext)
        }

        presentExplainer(for: parts.joined(separator: "\n"))
    }

    private func buildBookContext() -> String {
        guard !bookTitle.isEmpty else { return "" }
        var lines: [String] = ["Book: \"\(bookTitle)\""]
        if !bookAuthor.isEmpty { lines.append("Author: \(bookAuthor)") }
        if !bookDescription.isEmpty { lines.append("About: \(bookDescription)") }
        return lines.joined(separator: "\n")
    }

    func handleAnalysisRequest() {
        let visibleText = visibleTextOnScreen()
        guard !visibleText.isEmpty, visibleText != lastAnalyzedText else { return }
        lastAnalyzedText = visibleText

        analysisTask?.cancel()
        analysisTask = Task {
            await analyzeVisibleText(visibleText)
            guard !Task.isCancelled else { return }
            await performOpenAIQuery(for: visibleText)
        }
    }

    func analyzeVisibleText(_ text: String) async {
        let extracted = extractTagCandidates(from: text)
        guard !Task.isCancelled else { return }

        await MainActor.run {
            tags = mergedTags(primary: extracted, fallback: chapterTags, limit: maxTags)
        }
    }

    func seedChapterTags() {
        let candidates = extractTagCandidates(from: currentChapterTextForAnalysis(), limit: maxTags * 3)
        chapterTags = candidates
        tags = mergedTags(primary: tags, fallback: candidates, limit: maxTags)
    }

    func updateTagsForVisibleParagraphs(_ indices: [Int]) {
        let visibleText = textForAnalysis(indices: indices)
        guard !visibleText.isEmpty, visibleText != lastTaggedText else { return }
        lastTaggedText = visibleText
        let visibleTags = extractTagCandidates(from: visibleText, limit: maxTags)
        tags = mergedTags(primary: visibleTags, fallback: chapterTags, limit: maxTags)
    }

    func extractEntities(from text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text

        var seen = Set<String>()
        var entities: [String] = []
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        let entityTypes: Set<NLTag> = [.personalName, .placeName, .organizationName]

        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: options
        ) { tag, tokenRange in
            if let tag, entityTypes.contains(tag) {
                let name = String(text[tokenRange])
                if seen.insert(name).inserted {
                    entities.append(name)
                }
            }
            return true
        }
        return entities
    }

    func extractTagCandidates(from text: String, limit: Int? = nil) -> [String] {
        let limit = limit ?? maxTags
        let entities = extractEntities(from: text)
        let entityTags = mergedTags(primary: entities, fallback: [], limit: limit)
        guard entityTags.count < limit else { return entityTags }

        let keywords = extractKeywords(from: text)
        return mergedTags(primary: entities, fallback: keywords, limit: limit)
    }

    func extractKeywords(from text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text

        var counts: [String: Int] = [:]
        var displayText: [String: String] = [:]
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace]

        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: options
        ) { tag, tokenRange in
            guard tag == .noun else { return true }
            let token = String(text[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = normalizedTag(token)
            guard isUsefulKeyword(normalized) else { return true }

            counts[normalized, default: 0] += 1
            displayText[normalized] = displayText[normalized] ?? displayTag(for: token)
            return true
        }

        return counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .compactMap { displayText[$0.key] }
    }

    func mergedTags(primary: [String], fallback: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var merged: [String] = []
        for tag in primary + fallback {
            let display = displayTag(for: tag)
            let normalized = normalizedTag(display)
            guard isUsefulKeyword(normalized), seen.insert(normalized).inserted else { continue }
            merged.append(display)
            if merged.count == limit { break }
        }
        return merged
    }

    func displayTag(for tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.contains(where: { $0.isUppercase }) { return trimmed }
        return trimmed.prefix(1).uppercased() + String(trimmed.dropFirst())
    }

    func normalizedTag(_ tag: String) -> String {
        tag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    func isUsefulKeyword(_ normalized: String) -> Bool {
        guard normalized.count >= 4 else { return false }
        return !Self.tagStopwords.contains(normalized)
    }

    func currentChapterTextForAnalysis() -> String {
        guard chapters.indices.contains(chapterIndex) else {
            return items.map(textForAnalysis).joined(separator: " ")
        }
        let chapter = chapters[chapterIndex]
        return ([chapter.title] + chapter.items.map(textForAnalysis))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func textForAnalysis(indices: [Int]) -> String {
        indices
            .compactMap { items.indices.contains($0) ? textForAnalysis(items[$0]) : nil }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static let tagStopwords: Set<String> = [
        "about", "above", "after", "again", "against", "also", "another", "because", "before",
        "being", "between", "chapter", "could", "every", "from", "have", "into", "itself",
        "more", "most", "other", "over", "page", "pages", "part", "same", "some", "such",
        "than", "that", "their", "them", "then", "there", "these", "they", "this", "those",
        "through", "under", "very", "were", "what", "when", "where", "which", "while",
        "with", "would", "your"
    ]

    func performOpenAIQuery(for text: String) async {
        let key = Config.openAIKey
        guard !key.isEmpty else {
            print("OpenAI API key not configured — set OPENAI_API_KEY")
            return
        }

        await MainActor.run { isLoadingQuestion = true }

        var questionText: String?
        do {
            let openAI = OpenAI(apiToken: key)
            let prompt = "Find a short 5-10 word question you may have based on the following text: \(text)"

            let message = ChatQuery.ChatCompletionMessageParam.user(.init(content: .string(prompt)))
            let query = ChatQuery(messages: [message], model: .gpt3_5Turbo)
            let result = try await openAI.chats(query: query)
            questionText = result.choices.first?.message.content
        } catch is CancellationError {
        } catch {
            print("Failed to perform OpenAI query: \(error.localizedDescription)")
        }

        guard !Task.isCancelled else { return }
        await MainActor.run {
            if let questionText { currentQuestion = questionText }
            isLoadingQuestion = false
        }
    }
}
