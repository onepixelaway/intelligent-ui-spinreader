import Foundation

enum MarkdownParser {
    static func parse(text: String) -> [ScrollTextView.ReadableItem] {
        let lines = text.components(separatedBy: "\n")

        var items: [ScrollTextView.ReadableItem] = []
        var paragraphBuffer: [String] = []
        var codeBuffer: [String] = []
        var inCodeBlock = false

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            items.append(.paragraph(paragraphBuffer.joined(separator: " ")))
            paragraphBuffer.removeAll()
        }

        func flushCode() {
            items.append(.code(codeBuffer.joined(separator: "\n")))
            codeBuffer.removeAll()
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if inCodeBlock {
                if line.hasPrefix("```") {
                    flushCode()
                    inCodeBlock = false
                } else {
                    codeBuffer.append(rawLine)
                }
                continue
            }

            if line.hasPrefix("```") {
                flushParagraph()
                inCodeBlock = true
                continue
            }

            if line.isEmpty {
                flushParagraph()
                continue
            }

            if isHorizontalRule(line) {
                flushParagraph()
                items.append(.divider)
                continue
            }

            if let imageItem = parseImage(line) {
                flushParagraph()
                items.append(imageItem)
                continue
            }

            if line.hasPrefix("### ") {
                flushParagraph()
                items.append(.subheading(String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)))
                continue
            }

            if line.hasPrefix("## ") {
                flushParagraph()
                items.append(.subheading(String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)))
                continue
            }

            if line.hasPrefix("# ") {
                flushParagraph()
                items.append(.title(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                continue
            }

            if line.hasPrefix("> ") {
                flushParagraph()
                items.append(.blockquote(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if line == ">" {
                flushParagraph()
                items.append(.blockquote(""))
                continue
            }

            paragraphBuffer.append(stripInlineMarkdown(line))
        }

        if inCodeBlock {
            flushCode()
        }
        flushParagraph()

        return items
    }

    static func resolveTitle(userInput: String, from text: String) -> String {
        let trimmedUser = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedUser.isEmpty { return trimmedUser }
        if let heading = leadingHeadingTitle(in: text) { return heading }
        return "Untitled"
    }

    /// Returns the first non-empty line of `text` if it's a markdown heading
    /// (any leading `#` count), trimmed and capped to 60 characters.
    static func leadingHeadingTitle(in text: String) -> String? {
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard line.hasPrefix("#") else { return nil }
            let stripped = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty else { return nil }
            return String(stripped.prefix(60)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        return line.allSatisfy { $0 == "-" } || line.allSatisfy { $0 == "*" } || line.allSatisfy { $0 == "_" }
    }

    private static func parseImage(_ line: String) -> ScrollTextView.ReadableItem? {
        guard line.hasPrefix("![") else { return nil }
        guard let altEnd = line.firstIndex(of: "]") else { return nil }
        let altStart = line.index(line.startIndex, offsetBy: 2)
        guard altEnd >= altStart else { return nil }
        let urlOpenIndex = line.index(after: altEnd)
        guard urlOpenIndex < line.endIndex, line[urlOpenIndex] == "(" else { return nil }
        guard let urlEnd = line[urlOpenIndex...].firstIndex(of: ")") else { return nil }
        let alt = String(line[altStart..<altEnd])
        let urlStart = line.index(after: urlOpenIndex)
        let urlString = String(line[urlStart..<urlEnd]).trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: urlString) else { return nil }
        return .image(url: url, alt: alt.isEmpty ? nil : alt, caption: nil)
    }

    static func stripInlineMarkdown(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        var index = input.startIndex

        while index < input.endIndex {
            let ch = input[index]

            if ch == "!", let imageEnd = consumeInlineImage(input, from: index) {
                index = imageEnd
                continue
            }

            if ch == "[", let (linkText, linkEnd) = consumeLink(input, from: index) {
                result.append(linkText)
                index = linkEnd
                continue
            }

            if ch == "`", let (codeText, codeEnd) = consumeBalanced(input, from: index, marker: "`") {
                result.append(codeText)
                index = codeEnd
                continue
            }

            if ch == "*" || ch == "_" {
                let next = input.index(after: index)
                if next < input.endIndex, input[next] == ch {
                    let openEnd = input.index(after: next)
                    let marker = String(repeating: ch, count: 2)
                    if let (inner, end) = consumeBalanced(input, from: index, marker: marker, contentStart: openEnd) {
                        result.append(stripInlineMarkdown(inner))
                        index = end
                        continue
                    }
                }
                if let (inner, end) = consumeBalanced(input, from: index, marker: String(ch)) {
                    result.append(stripInlineMarkdown(inner))
                    index = end
                    continue
                }
            }

            result.append(ch)
            index = input.index(after: index)
        }

        return result
    }

    private static func consumeInlineImage(_ input: String, from start: String.Index) -> String.Index? {
        let bracketStart = input.index(after: start)
        guard bracketStart < input.endIndex, input[bracketStart] == "[" else { return nil }
        guard let bracketEnd = input[bracketStart...].firstIndex(of: "]") else { return nil }
        let parenStart = input.index(after: bracketEnd)
        guard parenStart < input.endIndex, input[parenStart] == "(" else { return nil }
        guard let parenEnd = input[parenStart...].firstIndex(of: ")") else { return nil }
        return input.index(after: parenEnd)
    }

    private static func consumeLink(_ input: String, from start: String.Index) -> (String, String.Index)? {
        guard let bracketEnd = input[start...].firstIndex(of: "]") else { return nil }
        let parenStart = input.index(after: bracketEnd)
        guard parenStart < input.endIndex, input[parenStart] == "(" else { return nil }
        guard let parenEnd = input[parenStart...].firstIndex(of: ")") else { return nil }
        let textStart = input.index(after: start)
        let linkText = String(input[textStart..<bracketEnd])
        return (linkText, input.index(after: parenEnd))
    }

    private static func consumeBalanced(
        _ input: String,
        from start: String.Index,
        marker: String,
        contentStart: String.Index? = nil
    ) -> (String, String.Index)? {
        let openEnd = contentStart ?? input.index(start, offsetBy: marker.count, limitedBy: input.endIndex)
        guard let contentStart = openEnd, contentStart <= input.endIndex else { return nil }
        guard let range = input.range(of: marker, range: contentStart..<input.endIndex),
              range.lowerBound > contentStart else { return nil }
        let inner = String(input[contentStart..<range.lowerBound])
        return (inner, range.upperBound)
    }
}
