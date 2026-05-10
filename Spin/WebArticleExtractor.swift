import Foundation
import WebKit

enum WebArticleError: LocalizedError {
    case scriptUnavailable
    case evaluationFailed(String)
    case decodingFailed
    case noContent

    var errorDescription: String? {
        switch self {
        case .scriptUnavailable: return "Couldn't load the article extractor script."
        case .evaluationFailed(let msg): return "Couldn't run the extractor: \(msg)"
        case .decodingFailed: return "Couldn't read the page text."
        case .noContent: return "Couldn't find readable content on this page."
        }
    }
}

private let readabilityScript: String? = {
    guard let scriptURL = Bundle.main.url(forResource: "ReadabilitySanitized", withExtension: "js") else {
        return nil
    }
    return try? String(contentsOf: scriptURL, encoding: .utf8)
}()

private let jsResultDecoder = JSONDecoder()

@MainActor
func extractArticle(from webView: WKWebView, sourceURL: URL) async throws -> WebArticle {
    guard let script = readabilityScript else {
        throw WebArticleError.scriptUnavailable
    }

    let injection = """
    if (typeof Readability === "undefined") {
    \(script)
    }
    """
    do {
        _ = try await webView.evaluateJavaScript(injection)
    } catch {
        throw WebArticleError.evaluationFailed(error.localizedDescription)
    }

    let runner = """
    try {
      var article = new Readability(document.cloneNode(true)).parse();
      if (!article || !article.content) {
        return JSON.stringify({ __error: 'No content' });
      }

      var coverImage = null;
      var coverMime = null;
      try {
        var temp = document.createElement('div');
        temp.innerHTML = article.content;
        var imgs = temp.querySelectorAll('img');
        var candidate = null;
        for (var i = 0; i < imgs.length; i++) {
          var img = imgs[i];
          var src = img.getAttribute('src') || img.getAttribute('data-src') || img.getAttribute('data-original') || '';
          if (!src) continue;
          var resolvedUrl;
          try { resolvedUrl = new URL(src, document.baseURI).href; } catch (e) { continue; }
          var w = parseInt(img.getAttribute('width'), 10) || img.naturalWidth || 0;
          var h = parseInt(img.getAttribute('height'), 10) || img.naturalHeight || 0;
          if (w > 0 && w < 100) continue;
          if (h > 0 && h < 100) continue;
          candidate = resolvedUrl;
          if (w === 0 || w >= 300) break;
        }

        if (candidate) {
          var resp = await fetch(candidate);
          if (resp.ok) {
            var blob = await resp.blob();
            coverMime = blob.type;
            coverImage = await new Promise(function(resolve) {
              var reader = new FileReader();
              reader.onloadend = function() {
                var s = reader.result || '';
                var idx = s.indexOf(',');
                resolve(idx >= 0 ? s.substring(idx + 1) : null);
              };
              reader.onerror = function() { resolve(null); };
              reader.readAsDataURL(blob);
            });
          }
        }
      } catch (e) { /* swallow cover extraction errors */ }

      return JSON.stringify({
        title: article.title,
        byline: article.byline,
        content: article.content,
        coverImage: coverImage,
        coverMime: coverMime
      });
    } catch(e) {
      return JSON.stringify({ __error: e.toString() });
    }
    """

    let resolvedURL = webView.url ?? sourceURL

    if let parsed: ReadabilityResult = try await evaluateAsyncJSON(runner, on: webView),
       let content = parsed.content, !content.isEmpty {
        var items = ReadabilityHTMLWalker.items(from: content, baseURL: resolvedURL)
        if let byline = parsed.byline?.trimmingCharacters(in: .whitespacesAndNewlines), !byline.isEmpty {
            items.insert(.byline(byline), at: 0)
        }
        if !items.isEmpty {
            let articleID = UUID()
            let coverPath = saveCoverImage(
                base64: parsed.coverImage,
                mime: parsed.coverMime,
                articleID: articleID
            )
            return WebArticle(
                id: articleID,
                title: resolveTitle(parsed.title, fallbackURL: resolvedURL),
                author: parsed.byline ?? "",
                sourceURL: resolvedURL,
                savedAt: Date(),
                items: items,
                coverImagePath: coverPath
            )
        }
    }

    return try await fallbackArticle(from: webView, sourceURL: resolvedURL)
}

private func saveCoverImage(base64: String?, mime: String?, articleID: UUID) -> String? {
    guard let base64, !base64.isEmpty,
          let data = Data(base64Encoded: base64), !data.isEmpty else { return nil }
    let ext = imageExtension(for: mime, data: data)
    let filename = "\(articleID.uuidString).\(ext)"
    let url = WebArticle.coversDirectory.appendingPathComponent(filename)
    do {
        try data.write(to: url, options: .atomic)
        return "web-covers/\(filename)"
    } catch {
        return nil
    }
}

private func imageExtension(for mime: String?, data: Data) -> String {
    if let mime = mime?.lowercased() {
        if mime.contains("png") { return "png" }
        if mime.contains("gif") { return "gif" }
        if mime.contains("webp") { return "webp" }
        if mime.contains("jpeg") || mime.contains("jpg") { return "jpg" }
    }
    if data.count >= 4 {
        let bytes = [UInt8](data.prefix(4))
        if bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 { return "png" }
        if bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return "jpg" }
        if bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 { return "gif" }
    }
    return "jpg"
}

@MainActor
private func fallbackArticle(from webView: WKWebView, sourceURL: URL) async throws -> WebArticle {
    let fallbackJS = """
    (function() {
      try {
        var t = (document.title || "").toString();
        var b = (document.body && document.body.innerText) ? document.body.innerText : "";
        if (b.length > 5000) { b = b.substring(0, 5000); }
        return JSON.stringify({ title: t, body: b });
      } catch(e) {
        return JSON.stringify({ __error: e.toString() });
      }
    })()
    """

    guard let fb: FallbackResult = try await evaluateJSON(fallbackJS, on: webView) else {
        throw WebArticleError.noContent
    }

    let body = (fb.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { throw WebArticleError.noContent }

    let paragraphs = body
        .components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .map { ScrollTextView.ReadableItem.paragraph($0) }

    guard !paragraphs.isEmpty else { throw WebArticleError.noContent }

    return WebArticle(
        id: UUID(),
        title: resolveTitle(fb.title, fallbackURL: sourceURL),
        author: "",
        sourceURL: sourceURL,
        savedAt: Date(),
        items: paragraphs
    )
}

private protocol JSEvalEnvelope: Decodable {
    var __error: String? { get }
}

private struct ReadabilityResult: JSEvalEnvelope {
    let title: String?
    let byline: String?
    let content: String?
    let coverImage: String?
    let coverMime: String?
    let __error: String?
}

private struct FallbackResult: JSEvalEnvelope {
    let title: String?
    let body: String?
    let __error: String?
}

@MainActor
private func evaluateJSON<T: JSEvalEnvelope>(_ js: String, on webView: WKWebView) async throws -> T? {
    let raw: Any?
    do {
        raw = try await webView.evaluateJavaScript(js)
    } catch {
        throw WebArticleError.evaluationFailed(error.localizedDescription)
    }
    return try decodeEnvelope(raw)
}

@MainActor
private func evaluateAsyncJSON<T: JSEvalEnvelope>(_ js: String, on webView: WKWebView) async throws -> T? {
    let raw: Any?
    do {
        raw = try await webView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
    } catch {
        throw WebArticleError.evaluationFailed(error.localizedDescription)
    }
    return try decodeEnvelope(raw)
}

private func decodeEnvelope<T: JSEvalEnvelope>(_ raw: Any?) throws -> T? {
    guard let json = raw as? String, !json.isEmpty, json != "null",
          let data = json.data(using: .utf8) else {
        return nil
    }
    let parsed: T
    do {
        parsed = try jsResultDecoder.decode(T.self, from: data)
    } catch {
        throw WebArticleError.decodingFailed
    }
    if let err = parsed.__error {
        throw WebArticleError.evaluationFailed(err)
    }
    return parsed
}

private func resolveTitle(_ raw: String?, fallbackURL: URL) -> String {
    if let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
        return trimmed
    }
    return fallbackURL.host ?? "Untitled"
}

// MARK: - HTML → ReadableItem walker

private enum ReadabilityHTMLWalker {
    static func items(from html: String, baseURL: URL) -> [ScrollTextView.ReadableItem] {
        let tokens = tokenize(html)
        return walk(tokens: tokens, baseURL: baseURL)
    }

    // MARK: Tokenizer

    private enum HTMLToken {
        case openTag(name: String, attrs: [String: String], selfClosing: Bool)
        case closeTag(name: String)
        case text(String)
    }

    private static func tokenize(_ html: String) -> [HTMLToken] {
        var tokens: [HTMLToken] = []
        let chars = Array(html)
        var i = 0
        var textBuffer = ""

        func flushText() {
            if !textBuffer.isEmpty {
                tokens.append(.text(textBuffer))
                textBuffer = ""
            }
        }

        while i < chars.count {
            let c = chars[i]
            if c != "<" {
                textBuffer.append(c)
                i += 1
                continue
            }

            if i + 3 < chars.count, chars[i+1] == "!", chars[i+2] == "-", chars[i+3] == "-" {
                var k = i + 4
                while k + 2 < chars.count, !(chars[k] == "-" && chars[k+1] == "-" && chars[k+2] == ">") {
                    k += 1
                }
                i = min(chars.count, k + 3)
                continue
            }
            if i + 1 < chars.count, chars[i+1] == "!" || chars[i+1] == "?" {
                var k = i + 1
                while k < chars.count && chars[k] != ">" { k += 1 }
                i = min(chars.count, k + 1)
                continue
            }

            var j = i + 1
            var inQuote: Character? = nil
            while j < chars.count {
                let ch = chars[j]
                if let q = inQuote {
                    if ch == q { inQuote = nil }
                } else if ch == "\"" || ch == "'" {
                    inQuote = ch
                } else if ch == ">" {
                    break
                }
                j += 1
            }
            if j >= chars.count {
                textBuffer.append(c)
                i += 1
                continue
            }

            flushText()
            let raw = String(chars[(i+1)..<j])
            i = j + 1

            let isClose = raw.hasPrefix("/")
            let stripped = isClose ? String(raw.dropFirst()) : raw
            let body = stripped.trimmingCharacters(in: .whitespaces)
            let selfClosing = !isClose && body.hasSuffix("/")
            let core = selfClosing ? String(body.dropLast()).trimmingCharacters(in: .whitespaces) : body

            var nameEnd = core.startIndex
            while nameEnd < core.endIndex, !core[nameEnd].isWhitespace {
                nameEnd = core.index(after: nameEnd)
            }
            let name = core[core.startIndex..<nameEnd].lowercased()
            let attrString = nameEnd < core.endIndex ? String(core[core.index(after: nameEnd)...]) : ""

            if isClose {
                tokens.append(.closeTag(name: name))
            } else {
                let attrs = parseAttrs(attrString)
                tokens.append(.openTag(name: name, attrs: attrs, selfClosing: selfClosing))
            }

            if !isClose && !selfClosing && (name == "script" || name == "style" || name == "noscript") {
                if let closeStart = findClosingTag(name: name, in: chars, from: i) {
                    var k = closeStart + 2 + name.count
                    while k < chars.count && chars[k] != ">" { k += 1 }
                    i = min(chars.count, k + 1)
                    tokens.append(.closeTag(name: name))
                } else {
                    i = chars.count
                }
            }
        }
        flushText()
        return tokens
    }

    private static func findClosingTag(name: String, in chars: [Character], from start: Int) -> Int? {
        let target = name.lowercased()
        let needed = target.count
        var i = start
        while i + 1 + needed <= chars.count {
            if chars[i] == "<", chars[i+1] == "/",
               String(chars[(i+2)..<(i+2+needed)]).lowercased() == target {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func parseAttrs(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            while i < chars.count && chars[i].isWhitespace { i += 1 }
            if i >= chars.count { break }
            let nameStart = i
            while i < chars.count && !chars[i].isWhitespace && chars[i] != "=" && chars[i] != "/" {
                i += 1
            }
            let name = String(chars[nameStart..<i]).lowercased()
            while i < chars.count && chars[i].isWhitespace { i += 1 }
            var value = ""
            if i < chars.count && chars[i] == "=" {
                i += 1
                while i < chars.count && chars[i].isWhitespace { i += 1 }
                if i < chars.count && (chars[i] == "\"" || chars[i] == "'") {
                    let q = chars[i]
                    i += 1
                    let valStart = i
                    while i < chars.count && chars[i] != q { i += 1 }
                    value = String(chars[valStart..<i])
                    if i < chars.count { i += 1 }
                } else {
                    let valStart = i
                    while i < chars.count && !chars[i].isWhitespace && chars[i] != ">" { i += 1 }
                    value = String(chars[valStart..<i])
                }
            }
            if !name.isEmpty {
                out[name] = decodeEntities(value)
            }
        }
        return out
    }

    // MARK: Walker

    private enum BlockType {
        case paragraph, subheading, blockquote, code
    }

    private static let inlineTags: Set<String> = [
        "a", "span", "em", "strong", "i", "b", "u", "s", "small",
        "mark", "sub", "sup", "abbr", "cite", "q", "time", "del", "ins",
        "kbd", "samp", "var", "ruby", "rb", "rt", "rp", "bdi", "bdo", "wbr"
    ]

    private static func walk(tokens: [HTMLToken], baseURL: URL) -> [ScrollTextView.ReadableItem] {
        var items: [ScrollTextView.ReadableItem] = []
        var buffer = ""
        var currentType: BlockType = .paragraph
        var listStack: [(ordered: Bool, index: Int)] = []
        var inPre = 0
        var inLi = false
        var pendingFigureCaption: String? = nil
        var inFigCaption = 0
        var figCaptionBuffer = ""

        func flush() {
            let text: String
            if currentType == .code {
                text = buffer.trimmingCharacters(in: CharacterSet.newlines.union(.whitespaces))
            } else {
                text = collapseWhitespace(buffer).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            buffer = ""
            guard !text.isEmpty else { return }
            switch currentType {
            case .paragraph:
                if let last = listStack.last, inLi {
                    items.append(.listItem(text, ordered: last.ordered, index: last.index))
                } else {
                    items.append(.paragraph(text))
                }
            case .subheading:
                items.append(.subheading(text))
            case .blockquote:
                items.append(.blockquote(text))
            case .code:
                items.append(.code(text))
            }
            currentType = .paragraph
        }

        for token in tokens {
            switch token {
            case .openTag(let name, let attrs, _):
                if inFigCaption > 0 {
                    if name == "figcaption" { inFigCaption += 1 }
                    continue
                }
                switch name {
                case "p":
                    flush()
                    currentType = .paragraph
                case "h1", "h2", "h3", "h4", "h5", "h6":
                    flush()
                    currentType = .subheading
                case "blockquote":
                    flush()
                    currentType = .blockquote
                case "pre":
                    flush()
                    currentType = .code
                    inPre += 1
                case "ul":
                    flush()
                    listStack.append((ordered: false, index: 1))
                case "ol":
                    flush()
                    let start = Int(attrs["start"] ?? "") ?? 1
                    listStack.append((ordered: true, index: start))
                case "li":
                    flush()
                    inLi = true
                    currentType = .paragraph
                case "br":
                    if inPre > 0 { buffer.append("\n") }
                    else if !buffer.isEmpty && !buffer.hasSuffix(" ") { buffer.append(" ") }
                case "hr":
                    flush()
                    items.append(.divider)
                case "img":
                    let rawSrc = attrs["src"] ?? attrs["data-src"] ?? attrs["data-original"] ?? ""
                    if let url = resolveURL(rawSrc, base: baseURL) {
                        flush()
                        let alt = (attrs["alt"]?.isEmpty == false) ? attrs["alt"] : nil
                        items.append(.image(url: url, alt: alt, caption: pendingFigureCaption))
                        pendingFigureCaption = nil
                    }
                case "figcaption":
                    inFigCaption = 1
                    figCaptionBuffer = ""
                case "figure":
                    flush()
                    pendingFigureCaption = nil
                default:
                    if !inlineTags.contains(name) {
                        flush()
                    }
                }
            case .closeTag(let name):
                if inFigCaption > 0 {
                    if name == "figcaption" {
                        inFigCaption -= 1
                        if inFigCaption == 0 {
                            let caption = collapseWhitespace(figCaptionBuffer).trimmingCharacters(in: .whitespacesAndNewlines)
                            figCaptionBuffer = ""
                            if !caption.isEmpty {
                                if case .image(let url, let alt, _) = items.last {
                                    items[items.count - 1] = .image(url: url, alt: alt, caption: caption)
                                } else {
                                    pendingFigureCaption = caption
                                }
                            }
                        }
                    }
                    continue
                }
                switch name {
                case "p", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6":
                    flush()
                case "pre":
                    flush()
                    inPre = max(0, inPre - 1)
                case "li":
                    flush()
                    inLi = false
                    if !listStack.isEmpty {
                        let last = listStack.removeLast()
                        listStack.append((ordered: last.ordered, index: last.index + 1))
                    }
                case "ul", "ol":
                    flush()
                    if !listStack.isEmpty { listStack.removeLast() }
                case "figure":
                    flush()
                    pendingFigureCaption = nil
                default:
                    break
                }
            case .text(let raw):
                let decoded = decodeEntities(raw)
                if inFigCaption > 0 {
                    figCaptionBuffer.append(decoded)
                } else {
                    buffer.append(decoded)
                }
            }
        }
        flush()
        return mergeAdjacent(items)
    }

    private static func mergeAdjacent(_ items: [ScrollTextView.ReadableItem]) -> [ScrollTextView.ReadableItem] {
        var out: [ScrollTextView.ReadableItem] = []
        for item in items {
            if case .divider = item, case .divider = out.last { continue }
            out.append(item)
        }
        return out
    }

    private static func resolveURL(_ raw: String, base: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        if trimmed.hasPrefix("//"), let scheme = base.scheme {
            return URL(string: "\(scheme):\(trimmed)")
        }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }

    // MARK: HTML helpers

    private static func collapseWhitespace(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var lastWasSpace = false
        for ch in s {
            if ch.isWhitespace || ch == "\u{00A0}" {
                if !lastWasSpace {
                    out.append(" ")
                    lastWasSpace = true
                }
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        return out
    }

    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] != "&" {
                out.append(chars[i])
                i += 1
                continue
            }
            var j = i + 1
            while j < chars.count && chars[j] != ";" && (j - i) < 12 { j += 1 }
            if j >= chars.count || chars[j] != ";" {
                out.append(chars[i])
                i += 1
                continue
            }
            let entity = String(chars[(i+1)..<j])
            if let value = decodeEntity(entity) {
                out.append(value)
            } else {
                out.append("&")
                out.append(entity)
                out.append(";")
            }
            i = j + 1
        }
        return out
    }

    private static func decodeEntity(_ entity: String) -> String? {
        if entity.hasPrefix("#") {
            let body = entity.dropFirst()
            let scalar: UInt32?
            if body.hasPrefix("x") || body.hasPrefix("X") {
                scalar = UInt32(body.dropFirst(), radix: 16)
            } else {
                scalar = UInt32(body, radix: 10)
            }
            if let s = scalar, let u = Unicode.Scalar(s) {
                return String(u)
            }
            return nil
        }
        return namedEntities[entity]
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "ndash": "\u{2013}", "mdash": "\u{2014}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "hellip": "\u{2026}", "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}",
        "deg": "\u{00B0}", "middot": "\u{00B7}", "bull": "\u{2022}", "laquo": "\u{00AB}",
        "raquo": "\u{00BB}", "iexcl": "\u{00A1}", "iquest": "\u{00BF}", "cent": "\u{00A2}",
        "pound": "\u{00A3}", "euro": "\u{20AC}", "yen": "\u{00A5}", "sect": "\u{00A7}",
        "para": "\u{00B6}", "times": "\u{00D7}", "divide": "\u{00F7}", "plusmn": "\u{00B1}"
    ]
}
