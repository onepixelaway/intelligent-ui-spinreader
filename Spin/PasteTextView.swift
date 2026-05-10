import SwiftUI
import UIKit
import NaturalLanguage

struct PasteTextView: View {
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    @State private var title: String = ""
    @State private var content: String = ""
    @State private var didPrefill = false
    @State private var titleSuggested = false
    @State private var suggestionTask: Task<Void, Never>?
    @FocusState private var bodyFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    TextField("", text: $title, prompt: titlePrompt)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .tint(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 0.5)

                    ZStack(alignment: .topLeading) {
                        if content.isEmpty {
                            Text("Paste markdown or plain text…")
                                .font(.system(size: 15))
                                .foregroundColor(.white.opacity(0.3))
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                .allowsHitTesting(false)
                        }

                        TextEditor(text: $content)
                            .font(.system(size: 15))
                            .foregroundColor(.white)
                            .tint(.white)
                            .scrollContentBackground(.hidden)
                            .background(Color.black)
                            .padding(.horizontal, 11)
                            .padding(.top, 4)
                            .focused($bodyFocused)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Paste Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCancel() }
                        .foregroundColor(.white.opacity(0.85))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { onSave(title, content) }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(canSave ? .white : .white.opacity(0.3))
                        .disabled(!canSave)
                }
            }
            .darkNavigationBar()
        }
        .preferredColorScheme(.dark)
        .onAppear {
            guard !didPrefill else { return }
            didPrefill = true
            if let pasted = clipboardText() {
                content = pasted
            }
            bodyFocused = true
        }
        .onChange(of: content) { _, newValue in
            handleContentChange(newValue)
        }
        .onDisappear {
            suggestionTask?.cancel()
        }
    }

    private var titlePrompt: Text {
        Text("Title (optional)")
            .foregroundColor(.white.opacity(0.3))
    }

    private var canSave: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func clipboardText() -> String? {
        let pb = UIPasteboard.general
        guard pb.hasStrings, let str = pb.string else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : str
    }

    private func handleContentChange(_ newContent: String) {
        let trimmed = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            titleSuggested = false
            suggestionTask?.cancel()
            return
        }
        guard title.isEmpty, !titleSuggested else { return }

        suggestionTask?.cancel()
        suggestionTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            guard title.isEmpty, !titleSuggested else { return }
            guard let suggestion = computeTitleSuggestion(from: newContent) else { return }
            title = suggestion
            titleSuggested = true
        }
    }

    private func computeTitleSuggestion(from text: String) -> String? {
        if let heading = markdownHeadingTitle(from: text) { return heading }
        if let firstLine = firstLineTitle(from: text) { return firstLine }
        if let extracted = nlExtractedTitle(from: text) { return extracted }
        return firstLineFallback(from: text)
    }

    private func firstLineTitle(from text: String) -> String? {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        guard let firstRaw = lines.first else { return nil }
        let firstLine = String(firstRaw).trimmingCharacters(in: .whitespaces)
        guard !firstLine.isEmpty, firstLine.count <= 100 else { return nil }

        let secondLine = lines.dropFirst().first
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        let secondIsEmpty = secondLine.isEmpty
        let secondMuchLonger = !secondIsEmpty && Double(secondLine.count) > Double(firstLine.count) * 1.5
        let endsWithQuestion = firstLine.hasSuffix("?")

        guard secondIsEmpty || secondMuchLonger || endsWithQuestion else { return nil }
        return firstLine
    }

    private func markdownHeadingTitle(from text: String) -> String? {
        let firstLine = text
            .split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline })
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard firstLine.hasPrefix("#") else { return nil }
        let stripped = firstLine
            .drop(while: { $0 == "#" })
            .trimmingCharacters(in: .whitespaces)
        guard !stripped.isEmpty else { return nil }
        return String(stripped.prefix(60)).trimmingCharacters(in: .whitespaces)
    }

    private func firstLineFallback(from text: String) -> String? {
        let lines = text.split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline })
        guard let firstNonEmpty = lines
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map({ $0.trimmingCharacters(in: .whitespaces) })
        else { return nil }
        let stripChars: Set<Character> = ["#", "*", "_", ">"]
        let cleaned = String(firstNonEmpty.filter { !stripChars.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces)
    }

    private func nlExtractedTitle(from text: String) -> String? {
        let snippet = String(text.prefix(500))
        let tagger = NLTagger(tagSchemes: [.nameTypeOrLexicalClass])
        tagger.string = snippet

        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        let nameTags: Set<NLTag> = [.personalName, .placeName, .organizationName]

        var properNouns: [String] = []
        var nouns: [String] = []
        var seen = Set<String>()

        tagger.enumerateTags(
            in: snippet.startIndex..<snippet.endIndex,
            unit: .word,
            scheme: .nameTypeOrLexicalClass,
            options: options
        ) { tag, tokenRange in
            guard let tag else { return true }
            let word = String(snippet[tokenRange]).trimmingCharacters(in: .whitespaces)
            guard word.count > 2 else { return true }
            let key = word.lowercased()
            guard !seen.contains(key) else { return true }

            if nameTags.contains(tag) {
                seen.insert(key)
                properNouns.append(word)
            } else if tag == .noun {
                seen.insert(key)
                nouns.append(word)
            }
            return true
        }

        var picked = Array(properNouns.prefix(5))
        if picked.count < 5 {
            picked.append(contentsOf: nouns.prefix(5 - picked.count))
        }
        guard picked.count >= 2 else { return nil }

        let joined = picked.prefix(5).map(titleCased).joined(separator: " ")
        return String(joined.prefix(60)).trimmingCharacters(in: .whitespaces)
    }

    private func titleCased(_ word: String) -> String {
        if word.contains(where: { $0.isUppercase }) { return word }
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst().lowercased()
    }
}
