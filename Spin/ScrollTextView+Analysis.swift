import SwiftUI
import NaturalLanguage
@preconcurrency import OpenAI

extension ScrollTextView {
    enum PerplexityAction {
        case learnMore
        case factCheck
    }

    func visibleTextOnScreen() -> String {
        visibleParagraphs
            .compactMap { items.indices.contains($0) ? textForAnalysis(items[$0]) : nil }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func openPerplexity(for action: PerplexityAction) {
        let visibleText = visibleTextOnScreen()
        guard !visibleText.isEmpty else { return }

        let query: String
        switch action {
        case .learnMore:
            query = """
            Help me learn more about this passage and explain any important context:

            \(visibleText)
            """
        case .factCheck:
            query = """
            Is this true or not? Fact-check this passage and explain why:

            \(visibleText)
            """
        }

        presentExplainer(for: query)
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
        let extracted = extractEntities(from: text)
        guard !Task.isCancelled else { return }

        await MainActor.run {
            var merged = tags
            for entity in extracted where !merged.contains(entity) {
                if merged.count < maxTags {
                    merged.append(entity)
                }
            }
            tags = Array(merged.prefix(maxTags))
        }
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

            if let message = ChatQuery.ChatCompletionMessageParam(role: .user, content: prompt) {
                let query = ChatQuery(messages: [message], model: .gpt3_5Turbo)
                let result = try await openAI.chats(query: query)
                if let s = result.choices.first?.message.content {
                    questionText = s
                }
            }
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
