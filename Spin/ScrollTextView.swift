import SwiftUI
import UIKit
import CoreHaptics
import NaturalLanguage
@preconcurrency import OpenAI
import QuartzCore
import SafariServices

struct PortraitOnlyModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                AppDelegate.orientationLock = .portrait
                requestPortrait()
            }
    }

    private func requestPortrait() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
    }
}

extension View {
    func portraitOnly() -> some View {
        self.modifier(PortraitOnlyModifier())
    }
}

private func perplexityURL(for query: String) -> URL? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    else { return nil }
    return URL(string: "https://www.perplexity.ai/search/new?q=\(encoded)")
}

struct IdentifiableURL: Identifiable {
    let url: URL
    var id: URL { url }
}

enum ReaderFontFamily: String, CaseIterable, Identifiable {
    case system
    case serif
    case monospaced

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .serif: return "Serif"
        case .monospaced: return "Mono"
        }
    }

    var design: Font.Design {
        switch self {
        case .system: return .default
        case .serif: return .serif
        case .monospaced: return .monospaced
        }
    }
}

enum ReaderLineSpacing: String, CaseIterable, Identifiable {
    case compact
    case normal
    case relaxed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact: return "Compact"
        case .normal: return "Normal"
        case .relaxed: return "Relaxed"
        }
    }

    var multiplier: CGFloat {
        switch self {
        case .compact: return 1.2
        case .normal: return 1.5
        case .relaxed: return 1.8
        }
    }
}

enum ReaderMargins: String, CaseIterable, Identifiable {
    case narrow
    case normal
    case wide

    var id: String { rawValue }

    var label: String {
        switch self {
        case .narrow: return "Narrow"
        case .normal: return "Normal"
        case .wide: return "Wide"
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .narrow: return 16
        case .normal: return 32
        case .wide: return 48
        }
    }
}

enum ReaderScrollMode: String, CaseIterable, Identifiable {
    case fluid
    case paginated

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fluid: return "Fluid"
        case .paginated: return "Chunked"
        }
    }
}

enum ReaderScrollControl: String, CaseIterable, Identifiable {
    case wheel
    case trackpad

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wheel: return "Wheel"
        case .trackpad: return "Trackpad"
        }
    }
}

@MainActor
final class ReaderSettings: ObservableObject {
    private enum Keys {
        static let fontSize = "reader.fontSize"
        static let lineSpacing = "reader.lineSpacing"
        static let fontFamily = "reader.fontFamily"
        static let margins = "reader.margins"
        static let dimLevel = "reader.dimLevel"
        static let scrollMode = "reader.scrollMode"
        static let scrollControl = "reader.scrollControl"
        static let showAIQuestions = "reader.showAIQuestions"
    }

    @Published var fontSize: Double {
        didSet {
            guard fontSize != oldValue else { return }
            UserDefaults.standard.set(fontSize, forKey: Keys.fontSize)
        }
    }
    @Published var lineSpacing: ReaderLineSpacing {
        didSet {
            guard lineSpacing != oldValue else { return }
            UserDefaults.standard.set(lineSpacing.rawValue, forKey: Keys.lineSpacing)
        }
    }
    @Published var fontFamily: ReaderFontFamily {
        didSet {
            guard fontFamily != oldValue else { return }
            UserDefaults.standard.set(fontFamily.rawValue, forKey: Keys.fontFamily)
        }
    }
    @Published var margins: ReaderMargins {
        didSet {
            guard margins != oldValue else { return }
            UserDefaults.standard.set(margins.rawValue, forKey: Keys.margins)
        }
    }
    @Published var dimLevel: Double {
        didSet {
            guard dimLevel != oldValue else { return }
            UserDefaults.standard.set(dimLevel, forKey: Keys.dimLevel)
        }
    }
    @Published var scrollMode: ReaderScrollMode {
        didSet {
            guard scrollMode != oldValue else { return }
            UserDefaults.standard.set(scrollMode.rawValue, forKey: Keys.scrollMode)
        }
    }
    @Published var scrollControl: ReaderScrollControl {
        didSet {
            guard scrollControl != oldValue else { return }
            UserDefaults.standard.set(scrollControl.rawValue, forKey: Keys.scrollControl)
        }
    }
    @Published var showAIQuestions: Bool {
        didSet {
            guard showAIQuestions != oldValue else { return }
            UserDefaults.standard.set(showAIQuestions, forKey: Keys.showAIQuestions)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        let storedSize = defaults.object(forKey: Keys.fontSize) as? Double
        self.fontSize = storedSize.map { min(max($0, 14), 28) } ?? 18
        self.lineSpacing = defaults.string(forKey: Keys.lineSpacing).flatMap(ReaderLineSpacing.init(rawValue:)) ?? .normal
        self.fontFamily = defaults.string(forKey: Keys.fontFamily).flatMap(ReaderFontFamily.init(rawValue:)) ?? .system
        self.margins = defaults.string(forKey: Keys.margins).flatMap(ReaderMargins.init(rawValue:)) ?? .normal
        self.dimLevel = min(max(defaults.double(forKey: Keys.dimLevel), 0), 0.7)
        self.scrollMode = defaults.string(forKey: Keys.scrollMode).flatMap(ReaderScrollMode.init(rawValue:)) ?? .fluid
        self.scrollControl = defaults.string(forKey: Keys.scrollControl).flatMap(ReaderScrollControl.init(rawValue:)) ?? .wheel
        self.showAIQuestions = defaults.object(forKey: Keys.showAIQuestions) as? Bool ?? true
    }

    var titleSize: CGFloat { CGFloat(fontSize) + 9 }
    var bylineSize: CGFloat { CGFloat(fontSize) + 3 }
    var paragraphSize: CGFloat { CGFloat(fontSize) }
    var blockquoteSize: CGFloat { max(12, CGFloat(fontSize) - 1) }
    var codeSize: CGFloat { max(10, CGFloat(fontSize) - 5) }
    var captionSize: CGFloat { max(10, CGFloat(fontSize) - 6) }

    func lineSpacingPt(for size: CGFloat) -> CGFloat {
        size * (lineSpacing.multiplier - 1.0) / 2
    }

    var paginatedChunkHeight: CGFloat {
        let size = paragraphSize
        let systemFontLineHeightRatio: CGFloat = 1.2
        let linesPerChunk: CGFloat = 5
        let lineToLine = size * systemFontLineHeightRatio + lineSpacingPt(for: size)
        return lineToLine * linesPerChunk
    }
}

final class HapticFeedback {
    private var engine: CHHapticEngine?
    private var lastHapticTime: CFTimeInterval = 0

    func prepare() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics, engine == nil else { return }
        do {
            let engine = try CHHapticEngine()
            try engine.start()
            self.engine = engine
        } catch {
            print("Haptic engine creation failed: \(error.localizedDescription)")
        }
    }

    func perform(speed: Double, minInterval: CFTimeInterval) {
        guard let engine else { return }
        let now = CACurrentMediaTime()
        guard now - lastHapticTime >= minInterval else { return }
        lastHapticTime = now

        do {
            let normalizedSpeed = min(abs(speed) / 10.0, 1.0)
            let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(0.3 + normalizedSpeed * 0.3))
            let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(0.3 + normalizedSpeed * 0.4))
            let duration = 0.08 - (normalizedSpeed * 0.04)
            let event = CHHapticEvent(eventType: .hapticTransient, parameters: [intensity, sharpness], relativeTime: 0, duration: duration)
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            print("Failed to play haptic pattern: \(error.localizedDescription)")
        }
    }
}

struct ScrollWheel: View {
    let onScrolled: (Double) -> Void

    @State private var startAngle: Double?
    @State private var rotation: Double = 0
    @State private var lastDelta: Double = 0
    @State private var lastDirection: Double = 0

    @State private var haptics = HapticFeedback()

    private let stepDegrees = 30.0
    private let hapticInterval: CFTimeInterval = 0.1

    var body: some View {
        GeometryReader { geo in
            let diameter = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

            ZStack {
                Circle()
                    .fill(.gray.opacity(0.06))

                Circle()
                    .stroke(.gray.opacity(0.22), lineWidth: diameter * (22.0 / 132.0))
                    .padding(diameter * (13.0 / 264.0))

                Circle()
                    .stroke(.white.opacity(0.17), lineWidth: 2)
                    .padding(diameter * (33.0 / 264.0))

                Circle()
                    .fill(.white)
                    .frame(width: diameter * (22.0 / 132.0), height: diameter * (22.0 / 132.0))
                    .offset(y: -diameter * (60.0 / 132.0))
                    .rotationEffect(.degrees(rotation))
            }
            .contentShape(Circle())
            .onAppear { haptics.prepare() }
            .gesture(dragGesture(center: center))
        }
    }

    private func dragGesture(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                let currentAngle = angle(from: center, to: gesture.location)

                guard let start = startAngle else {
                    startAngle = currentAngle
                    lastDelta = 0
                    lastDirection = 0
                    return
                }

                var delta = currentAngle - start
                if delta > 180 { delta -= 360 }
                else if delta < -180 { delta += 360 }

                let movement = delta - lastDelta
                lastDelta = delta

                if abs(movement) > 0.5 {
                    lastDirection = movement > 0 ? -1.0 : 1.0
                }

                let previousRotation = rotation
                rotation += movement

                let currentStep = floor(abs(rotation) / stepDegrees)
                let previousStep = floor(abs(previousRotation) / stepDegrees)

                if currentStep != previousStep, lastDirection != 0 {
                    onScrolled(lastDirection)
                    haptics.perform(speed: abs(movement) / 0.016, minInterval: hapticInterval)
                }
            }
            .onEnded { _ in
                startAngle = nil
                lastDelta = 0
                lastDirection = 0
            }
    }

    private func angle(from center: CGPoint, to point: CGPoint) -> Double {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let degrees = atan2(dy, dx) * (180.0 / .pi)
        return (degrees + 90.0).truncatingRemainder(dividingBy: 360.0)
    }
}

struct TrackpadScrollView: View {
    let onDrag: (Double) -> Void   // positive delta = swipe down (scroll content up)
    let onFlick: (Double) -> Void  // ±1 direction on fast release

    @State private var haptics = HapticFeedback()
    @State private var hapticAccumulator: CGFloat = 0
    @State private var lastTranslation: CGFloat = 0

    private let hapticInterval: CFTimeInterval = 0.08
    private let hapticStepPoints: CGFloat = 40.0
    private let flickThreshold: CGFloat = 35.0

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.06))

                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 36, height: 5)
                    .padding(.top, 10)
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .onAppear { haptics.prepare() }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let current = value.translation.height
                        let delta = current - lastTranslation
                        lastTranslation = current

                        if delta != 0 {
                            onDrag(Double(delta))

                            hapticAccumulator += abs(delta)
                            if hapticAccumulator >= hapticStepPoints {
                                hapticAccumulator = 0
                                haptics.perform(speed: abs(Double(delta)) * 5, minInterval: hapticInterval)
                            }
                        }
                    }
                    .onEnded { value in
                        lastTranslation = 0
                        hapticAccumulator = 0
                        let extraMomentum = value.predictedEndTranslation.height - value.translation.height
                        if abs(extraMomentum) > flickThreshold {
                            onFlick(extraMomentum > 0 ? 1.0 : -1.0)
                        }
                    }
            )
        }
    }
}

struct ScrollTextView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(HighlightStore.self) private var highlightStore

    @StateObject private var scrollState = ScrollState()
    @StateObject private var readerSettings = ReaderSettings()
    @State private var showTopGradient: Bool = false
    @State private var visibleParagraphs: [Int] = []
    @State private var spinCount: Int = 0
    @State private var lastAnalyzedText: String = ""
    @State private var tags: [String] = []
    @State private var currentQuestion: String = ""
    @State private var isLoadingQuestion: Bool = false
    @State private var explainerURL: IdentifiableURL?
    @State private var analysisTask: Task<Void, Never>?
    @State private var showReaderSettings: Bool = false
    @State private var showHighlightsList: Bool = false
    @State private var activeFootnote: String? = nil
    @State private var isLoadingNextChapter: Bool = false
    @State private var autoHighlightAnimating: Bool = false
    @State private var paragraphFrames: [Int: CGRect] = [:]
    @State private var storedScrollViewHeight: CGFloat = 0
    @State private var storedViewportWidth: CGFloat = 0

    struct RichText: Hashable, @unchecked Sendable {
        let attributedString: NSAttributedString

        func hash(into hasher: inout Hasher) {
            hasher.combine(attributedString.string)
        }

        static func == (lhs: RichText, rhs: RichText) -> Bool {
            lhs.attributedString.isEqual(to: rhs.attributedString)
        }
    }

    struct FootnoteRef: Hashable, Sendable {
        let marker: String
        let content: String
    }

    enum ReadableItem: Hashable, Sendable {
        case title(String)
        case byline(String)
        case paragraph(String)
        case richParagraph(RichText)
        case subheading(String)
        case listItem(String, ordered: Bool, index: Int)
        case image(url: URL, alt: String?, caption: String?)
        case blockquote(String)
        case code(String)
        case video(videoURL: URL, thumbnailURL: URL?, provider: VideoProvider)
        case divider
        case callout(String)
        case paragraphWithFootnotes(text: String, footnotes: [FootnoteRef])
        case chapterTOC([String])
    }

    @State private var items: [ReadableItem]
    private let chapters: [EpubChapter]
    @State private var chapterIndex: Int
    private let showsBackButton: Bool
    private let article: Article?
    private let contentID: String
    private let bookID: String?
    @State private var itemContentIDs: [String] = []
    private let topPadding: CGFloat = 20
    private let backButtonTopPadding: CGFloat = 64
    private let maxTags = 5
    private let topGradientThreshold: CGFloat = 200

    init() {
        let paragraphs = StoryText.content
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var built: [ReadableItem] = []
        if paragraphs.count >= 1 { built.append(.title(paragraphs[0])) }
        if paragraphs.count >= 2 { built.append(.byline(paragraphs[1])) }
        if paragraphs.count > 2 {
            for paragraph in paragraphs[2...] {
                built.append(.paragraph(paragraph))
            }
        }

        _items = State(initialValue: built)
        self.chapters = []
        _chapterIndex = State(initialValue: 0)
        self.showsBackButton = false
        self.article = nil
        self.contentID = "story"
        self.bookID = nil
        _itemContentIDs = State(initialValue: Array(repeating: "story", count: built.count))
    }

    init(article: Article) {
        var built: [ReadableItem] = []
        let trimmedTitle = article.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { built.append(.title(trimmedTitle)) }

        var bylineParts: [String] = []
        if let category = article.category?.trimmingCharacters(in: .whitespacesAndNewlines),
           !category.isEmpty {
            bylineParts.append(category)
        }
        if let author = article.author?.trimmingCharacters(in: .whitespacesAndNewlines),
           !author.isEmpty {
            bylineParts.append(author)
        }
        if !bylineParts.isEmpty {
            built.append(.byline(bylineParts.joined(separator: " · ")))
        }

        for block in article.blocks {
            switch block {
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { built.append(.paragraph(trimmed)) }
            case .image(let url, let alt, let caption):
                built.append(.image(url: url, alt: alt, caption: caption))
            case .blockquote(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { built.append(.blockquote(trimmed)) }
            case .code(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { built.append(.code(trimmed)) }
            case .video(let videoURL, let thumbnailURL, let provider):
                built.append(.video(videoURL: videoURL, thumbnailURL: thumbnailURL, provider: provider))
            }
        }

        _items = State(initialValue: built)
        self.chapters = []
        _chapterIndex = State(initialValue: 0)
        self.showsBackButton = true
        self.article = article
        self.contentID = article.id
        self.bookID = nil
        _itemContentIDs = State(initialValue: Array(repeating: article.id, count: built.count))
    }

    init(items: [ReadableItem], title: String) {
        var built = items
        let hasLeadingTitle: Bool = {
            if let first = built.first, case .title = first { return true }
            return false
        }()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hasLeadingTitle && !trimmedTitle.isEmpty {
            built.insert(.title(trimmedTitle), at: 0)
        }
        let cid = "custom:\(title)"
        _items = State(initialValue: built)
        self.chapters = []
        _chapterIndex = State(initialValue: 0)
        self.showsBackButton = true
        self.article = nil
        self.contentID = cid
        self.bookID = nil
        _itemContentIDs = State(initialValue: Array(repeating: cid, count: built.count))
    }

    init(chapters: [EpubChapter], startingIndex: Int, bookID: String = "") {
        let chapter = chapters[startingIndex]
        var built = chapter.items
        let hasLeadingTitle: Bool = {
            if let first = built.first, case .title = first { return true }
            return false
        }()
        let trimmedTitle = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hasLeadingTitle && !trimmedTitle.isEmpty {
            built.insert(.title(trimmedTitle), at: 0)
        }
        let cid = "\(bookID):\(chapter.xhtmlPath)"
        _items = State(initialValue: built)
        self.chapters = chapters
        _chapterIndex = State(initialValue: startingIndex)
        self.showsBackButton = true
        self.article = nil
        self.contentID = cid
        self.bookID = bookID
        _itemContentIDs = State(initialValue: Array(repeating: cid, count: built.count))
    }

    private func textForAnalysis(_ item: ReadableItem) -> String {
        switch item {
        case .title(let text), .byline(let text), .paragraph(let text), .blockquote(let text), .code(let text), .subheading(let text), .callout(let text):
            return text
        case .richParagraph(let rt):
            return rt.attributedString.string
        case .listItem(let text, _, _):
            return text
        case .image(_, let alt, let caption):
            return [alt, caption].compactMap { $0 }.joined(separator: " ")
        case .video:
            return ""
        case .divider:
            return ""
        case .paragraphWithFootnotes(let text, _):
            return text
        case .chapterTOC(let entries):
            return entries.joined(separator: "\n")
        }
    }

    struct TagView: View {
        let text: String
        @State private var sheetURL: IdentifiableURL?

        var body: some View {
            Text(text)
                .font(.system(size: 14))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(Color.gray.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .cornerRadius(14)
                .onTapGesture {
                    if let url = perplexityURL(for: text) {
                        sheetURL = IdentifiableURL(url: url)
                    }
                }
                .sheet(item: $sheetURL) { item in
                    SafariView(url: item.url)
                }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let scrollViewHeight = geometry.size.height * 0.65
            ZStack(alignment: .top) {
                ScrollViewReader { _ in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                                readableItemView(item, index: index)
                                    .id(index)
                                    .padding(.horizontal, horizontalPadding(for: item))
                                    .background(
                                        GeometryReader { geo in
                                            Color.clear
                                                .preference(key: ParagraphPositionKey.self, value: [index: geo.frame(in: .named("scroll"))])
                                        }
                                    )
                            }
                        }
                        .padding(.top, showsBackButton ? backButtonTopPadding : topPadding)
                        .padding(.bottom, 100)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                            }
                        )
                        .offset(y: scrollState.offset)
                    }
                    .coordinateSpace(name: "scroll")
                    .frame(maxWidth: .infinity, maxHeight: scrollViewHeight, alignment: .top)
                    .scrollDisabled(true)
                    .onPreferenceChange(ParagraphPositionKey.self) { positions in
                        let visibleHeight = scrollViewHeight * 0.60
                        let viewport = CGRect(x: 0, y: 0, width: geometry.size.width, height: visibleHeight)
                        visibleParagraphs = positions
                            .filter { $0.value.intersects(viewport) }
                            .map { $0.key }
                            .sorted()
                        paragraphFrames = positions
                        storedScrollViewHeight = scrollViewHeight
                        storedViewportWidth = geometry.size.width
                    }
                    .onPreferenceChange(ContentHeightKey.self) { h in
                        scrollState.setScrollBounds(
                            contentHeight: Double(h),
                            viewportHeight: Double(scrollViewHeight)
                        )
                        if isLoadingNextChapter {
                            isLoadingNextChapter = false
                        }
                    }
                    .overlay(alignment: .bottom) {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .clear, location: 0.25),
                                .init(color: .black.opacity(0.6), location: 0.7),
                                .init(color: .black, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: scrollViewHeight * 0.55)
                        .allowsHitTesting(false)
                    }
                }
                .clipped()

                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: geometry.size.height * 0.15)
                .allowsHitTesting(false)
                .opacity(showTopGradient ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: showTopGradient)
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.075)
            }

            Group {
                if readerSettings.scrollControl == .wheel {
                    ScrollWheel { direction in
                        showTopGradient = abs(scrollState.offset) > topGradientThreshold
                        let chunk: CGFloat? = readerSettings.scrollMode == .paginated ? readerSettings.paginatedChunkHeight : nil
                        if direction < 0 && scrollState.isAtBottom {
                            advanceToNextChapter()
                            return
                        }
                        scrollState.handleScroll(direction: direction, paginatedChunk: chunk)
                        spinCount += 1
                        if spinCount >= 2 {
                            spinCount = 0
                            handleAnalysisRequest()
                        }
                    }
                } else {
                    TrackpadScrollView(
                        onDrag: { delta in
                            if delta < 0 && scrollState.isAtBottom {
                                advanceToNextChapter()
                                return
                            }
                            scrollState.applyDirectDelta(delta)
                            showTopGradient = abs(scrollState.offset) > topGradientThreshold
                        },
                        onFlick: { direction in
                            if direction < 0 && scrollState.isAtBottom {
                                advanceToNextChapter()
                                return
                            }
                            scrollState.applyFlick(direction: direction)
                            showTopGradient = abs(scrollState.offset) > topGradientThreshold
                            spinCount += 1
                            if spinCount >= 2 {
                                spinCount = 0
                                handleAnalysisRequest()
                            }
                        }
                    )
                }
            }
            .frame(width: geometry.size.width * 0.3, height: geometry.size.width * 0.3)
            .position(x: geometry.size.width / 2, y: geometry.size.height * 0.76)

            if !visibleParagraphs.isEmpty {
                Button {
                    autoHighlightVisibleSentences()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        autoHighlightAnimating = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            autoHighlightAnimating = false
                        }
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.yellow.opacity(0.85))
                            .frame(width: 52, height: 52)
                            .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                        Image(systemName: autoHighlightAnimating ? "checkmark" : "highlighter")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.black.opacity(0.75))
                    }
                    .scaleEffect(autoHighlightAnimating ? 1.1 : 1.0)
                }
                .position(x: geometry.size.width * 0.35 - 36, y: geometry.size.height * 0.76)
            }

            if readerSettings.showAIQuestions {
                VStack(spacing: 4) {
                    if !tags.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(tags.prefix(maxTags), id: \.self) { tag in
                                TagView(text: tag)
                            }
                        }
                        .frame(maxHeight: 70)
                        .padding(.horizontal, 16)
                    }

                    Text(currentQuestion)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.gray.opacity(0.7))
                        .padding(.top, 4)
                        .opacity(isLoadingQuestion ? 0.5 : 1.0)
                        .animation(.easeInOut(duration: 0.2), value: isLoadingQuestion)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .onTapGesture {
                            if let url = perplexityURL(for: currentQuestion) {
                                explainerURL = IdentifiableURL(url: url)
                            }
                        }
                        .sheet(item: $explainerURL) { item in
                            SafariView(url: item.url)
                        }
                }
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.91)
            }

            if showsBackButton {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .position(x: 30, y: 30)

                Button {
                    showHighlightsList = true
                } label: {
                    Image(systemName: "highlighter")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .position(x: geometry.size.width - (article != nil ? 118 : 74), y: 30)

                Button {
                    showReaderSettings = true
                } label: {
                    Image(systemName: "textformat.size")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .position(x: geometry.size.width - (article != nil ? 74 : 30), y: 30)

                if let article {
                    ShareButton(article: article)
                        .position(x: geometry.size.width - 30, y: 30)
                }
            }

            if readerSettings.dimLevel > 0 {
                Color.black
                    .opacity(readerSettings.dimLevel)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .background(Color.black)
        .portraitOnly()
        .gesture(
            DragGesture(minimumDistance: 20, coordinateSpace: .global)
                .onEnded { value in
                    guard value.startLocation.x < 60 else { return }
                    let dx = value.translation.width
                    let dy = abs(value.translation.height)
                    if dx > 50 && dy < dx * 0.75 {
                        dismiss()
                    }
                }
        )
        .environmentObject(readerSettings)
        .sheet(isPresented: $showReaderSettings) {
            ReaderSettingsSheet(settings: readerSettings)
        }
        .sheet(isPresented: $showHighlightsList) {
            HighlightsListView(contentIDs: Array(Set(itemContentIDs)))
        }
        .overlay(alignment: .bottom) {
            if let footnote = activeFootnote {
                FootnoteOverlay(text: footnote) {
                    activeFootnote = nil
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: activeFootnote)
    }

    private func advanceToNextChapter() {
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
        let newContentID = bookID.map { "\($0):\(chapter.xhtmlPath)" } ?? contentID
        itemContentIDs.append(contentsOf: Array(repeating: newContentID, count: newItems.count))

        tags = []
        currentQuestion = ""
        lastAnalyzedText = ""
        spinCount = 0
    }

    private func autoHighlightVisibleSentences() {
        let visibleHeight = storedScrollViewHeight * 0.60
        let viewport = CGRect(x: 0, y: 0, width: storedViewportWidth, height: visibleHeight)
        let tokenizer = NLTokenizer(unit: .sentence)
        for index in visibleParagraphs {
            guard items.indices.contains(index) else { continue }
            guard let frame = paragraphFrames[index], viewport.contains(frame) else { continue }
            let text = textForAnalysis(items[index])
            guard !text.isEmpty else { continue }
            let cid = contentIDForItem(at: index)
            let existing = highlightStore.highlights(for: cid)

            tokenizer.string = text
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard sentence.count >= 5 else { return true }
                if existing.contains(where: { $0.text == sentence }) { return true }
                let startOffset = text.distance(from: text.startIndex, to: range.lowerBound)
                let endOffset = text.distance(from: text.startIndex, to: range.upperBound)
                highlightStore.add(Highlight(contentID: cid, text: sentence, startOffset: startOffset, endOffset: endOffset))
                return true
            }
        }
    }

    private func handleAnalysisRequest() {
        let visibleText = visibleParagraphs
            .compactMap { items.indices.contains($0) ? textForAnalysis(items[$0]) : nil }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !visibleText.isEmpty, visibleText != lastAnalyzedText else { return }
        lastAnalyzedText = visibleText

        analysisTask?.cancel()
        analysisTask = Task {
            await analyzeVisibleText(visibleText)
            guard !Task.isCancelled else { return }
            await performOpenAIQuery(for: visibleText)
        }
    }

    @ViewBuilder
    private func readableItemView(_ item: ReadableItem, index: Int) -> some View {
        switch item {
        case .title(let text):
            highlightableTextBlock(text, size: readerSettings.titleSize, fontWeight: .bold, itemIndex: index)
        case .byline(let text):
            highlightableTextBlock(text, size: readerSettings.bylineSize, fontWeight: .semibold, itemIndex: index)
        case .paragraph(let text):
            highlightableTextBlock(text, size: readerSettings.paragraphSize, fontWeight: .regular, itemIndex: index)
        case .richParagraph(let rt):
            highlightableRichTextBlock(rt, size: readerSettings.paragraphSize, itemIndex: index)
        case .subheading(let text):
            highlightableTextBlock(text, size: readerSettings.titleSize - 4, fontWeight: .bold, itemIndex: index)
        case .listItem(let text, let ordered, let listIdx):
            let prefix = ordered ? "\(listIdx). " : "\u{2022} "
            let fullText = prefix + text
            highlightableTextBlock(fullText, size: readerSettings.paragraphSize, fontWeight: .regular, itemIndex: index, extraLeading: 16)
        case .image(let url, let alt, let caption):
            ArticleImageView(url: url, alt: alt, caption: caption)
        case .blockquote(let text):
            AccentedQuoteView(text: text)
        case .code(let text):
            CodeBlockView(text: text)
        case .video(let videoURL, let thumbnailURL, let provider):
            VideoEmbedView(videoURL: videoURL, thumbnailURL: thumbnailURL, provider: provider)
        case .divider:
            Text("·  ·  ·")
                .font(.system(size: readerSettings.paragraphSize, weight: .regular, design: readerSettings.fontFamily.design))
                .foregroundColor(Color(white: 0.6, opacity: 0.6))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
        case .callout(let text):
            AccentedQuoteView(text: text, barOpacity: 0.45, textWhite: 0.85, hasBackground: true)
        case .paragraphWithFootnotes(let text, let footnotes):
            FootnoteParagraphView(text: text, footnotes: footnotes, activeFootnote: $activeFootnote)
        case .chapterTOC(let entries):
            ChapterTOCView(entries: entries)
        }
    }

    private func horizontalPadding(for item: ReadableItem) -> CGFloat {
        let base = readerSettings.margins.horizontalPadding
        return item.usesWideHorizontalPadding ? max(8, base - 12) : base
    }

    private func contentIDForItem(at index: Int) -> String {
        guard index < itemContentIDs.count else { return contentID }
        return itemContentIDs[index]
    }

    private func highlightsForParagraph(_ text: String, itemIndex: Int) -> [Highlight] {
        let cid = contentIDForItem(at: itemIndex)
        return highlightStore.highlights(for: cid).filter { h in
            guard h.startOffset >= 0, h.endOffset <= text.count, h.startOffset < h.endOffset else { return false }
            let s = text.index(text.startIndex, offsetBy: h.startOffset)
            let e = text.index(text.startIndex, offsetBy: h.endOffset)
            return String(text[s..<e]) == h.text
        }
    }

    private func nsStyledText(_ text: String, size: CGFloat, weight: UIFont.Weight) -> NSAttributedString {
        var font = UIFont.systemFont(ofSize: size, weight: weight)
        let design: UIFontDescriptor.SystemDesign = {
            switch readerSettings.fontFamily {
            case .system: return .default
            case .serif: return .serif
            case .monospaced: return .monospaced
            }
        }()
        if let descriptor = font.fontDescriptor.withDesign(design) {
            font = UIFont(descriptor: descriptor, size: size)
        }
        let para = NSMutableParagraphStyle()
        para.lineSpacing = readerSettings.lineSpacingPt(for: size)
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor(white: 0.92, alpha: 1.0),
            .paragraphStyle: para
        ])
    }

    private func nsRichAttributedText(_ rt: RichText, size: CGFloat) -> NSAttributedString {
        let ns = rt.attributedString
        let result = NSMutableAttributedString()
        let design: UIFontDescriptor.SystemDesign = {
            switch readerSettings.fontFamily {
            case .system: return .default
            case .serif: return .serif
            case .monospaced: return .monospaced
            }
        }()
        let para = NSMutableParagraphStyle()
        para.lineSpacing = readerSettings.lineSpacingPt(for: size)
        ns.enumerateAttributes(in: NSRange(location: 0, length: ns.length)) { attrs, range, _ in
            let substring = ns.attributedSubstring(from: range).string
            let uiFont = attrs[.font] as? UIFont
            let traits = uiFont?.fontDescriptor.symbolicTraits ?? []
            let isBold = traits.contains(.traitBold)
            let isItalic = traits.contains(.traitItalic)
            let weight: UIFont.Weight = isBold ? .bold : .regular
            var font = UIFont.systemFont(ofSize: size, weight: weight)
            if let descriptor = font.fontDescriptor.withDesign(design) {
                font = UIFont(descriptor: descriptor, size: size)
            }
            if isItalic, let italicDesc = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
                font = UIFont(descriptor: italicDesc, size: size)
            }
            let chunk = NSAttributedString(string: substring, attributes: [
                .font: font,
                .foregroundColor: UIColor(white: 0.92, alpha: 1.0),
                .paragraphStyle: para
            ])
            result.append(chunk)
        }
        return result
    }

    private static func uiFontWeight(from swiftUIWeight: Font.Weight) -> UIFont.Weight {
        switch swiftUIWeight {
        case .bold: return .bold
        case .semibold: return .semibold
        case .medium: return .medium
        case .light: return .light
        case .thin: return .thin
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }

    @ViewBuilder
    private func highlightableTextBlock(_ text: String, size: CGFloat, fontWeight: Font.Weight, itemIndex: Int, extraLeading: CGFloat = 0) -> some View {
        let matching = highlightsForParagraph(text, itemIndex: itemIndex)
        let cid = contentIDForItem(at: itemIndex)
        let nsAttr = nsStyledText(text, size: size, weight: Self.uiFontWeight(from: fontWeight))
        HighlightableTextView(
            text: text,
            attributedText: nsAttr,
            highlights: matching,
            onHighlightCreated: { selectedText, start, end in
                highlightStore.add(Highlight(contentID: cid, text: selectedText, startOffset: start, endOffset: end))
            },
            onHighlightRemoved: { id in
                highlightStore.remove(id: id)
            }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, extraLeading)
    }

    @ViewBuilder
    private func highlightableRichTextBlock(_ rt: RichText, size: CGFloat, itemIndex: Int) -> some View {
        let text = rt.attributedString.string
        let matching = highlightsForParagraph(text, itemIndex: itemIndex)
        let cid = contentIDForItem(at: itemIndex)
        let nsAttr = nsRichAttributedText(rt, size: size)
        HighlightableTextView(
            text: text,
            attributedText: nsAttr,
            highlights: matching,
            onHighlightCreated: { selectedText, start, end in
                highlightStore.add(Highlight(contentID: cid, text: selectedText, startOffset: start, endOffset: end))
            },
            onHighlightRemoved: { id in
                highlightStore.remove(id: id)
            }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func analyzeVisibleText(_ text: String) async {
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

    private func extractEntities(from text: String) -> [String] {
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

    private func performOpenAIQuery(for text: String) async {
        let key = Config.openAIKey
        guard !key.isEmpty else {
            print("OpenAI API key not configured — set OPENAI_API_KEY or Info.plist OpenAIAPIKey")
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
                questionText = result.choices.first?.message.content
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

@MainActor
final class ScrollState: ObservableObject {
    @Published var offset: Double = 0
    private var velocity: Double = 0
    private var lastScrollTime = CACurrentMediaTime()
    private var momentumTask: Task<Void, Never>?

    private let baseScrollSpeed: Double = 7
    private let maxVelocity: Double = 40.0
    private let deceleration: Double = 0.3
    private let acceleration: Double = 4
    private let activeFrameNanos: UInt64 = 8_333_333
    private let idleFrameNanos: UInt64 = 50_000_000
    private let momentumSpring = Animation.interpolatingSpring(stiffness: 170, damping: 25)
    private let paginatedSnapSpring = Animation.spring(response: 0.35, dampingFraction: 0.85)

    init() {
        startMomentumTimer()
    }

    deinit {
        momentumTask?.cancel()
    }

    private var contentHeight: Double = 0
    private var viewportHeight: Double = 0
    private var minOffset: Double { guard contentHeight > viewportHeight else { return 0 }; return -(contentHeight - viewportHeight) - 120 }
    private var maxOffset: Double { 0 }

    var isAtBottom: Bool {
        guard contentHeight > viewportHeight else { return false }
        let contentBottom = -(contentHeight - viewportHeight)
        return offset <= contentBottom + 5
    }

    func setScrollBounds(contentHeight: Double, viewportHeight: Double) {
        self.contentHeight = contentHeight
        self.viewportHeight = viewportHeight
    }

    private func clamp(_ value: Double) -> Double {
        min(maxOffset, max(minOffset, value))
    }

    func applyDirectDelta(_ delta: Double) {
        let proposed = offset + delta
        if proposed > maxOffset || proposed < minOffset {
            offset += delta * 0.25
        } else {
            offset = proposed
        }
    }

    func applyFlick(direction: Double) {
        velocity = direction * maxVelocity
        lastScrollTime = CACurrentMediaTime()
        withAnimation(momentumSpring) {
            offset = clamp(offset + velocity * 3)
        }
    }

    func handleScroll(direction: Double, paginatedChunk: CGFloat? = nil) {
        let now = CACurrentMediaTime()
        let timeDelta = now - lastScrollTime
        lastScrollTime = now

        if let chunk = paginatedChunk, chunk > 0 {
            velocity = 0
            let step = direction * Double(chunk)
            let target = offset + step
            let snapped = (target / Double(chunk)).rounded() * Double(chunk)
            guard snapped != offset else { return }
            withAnimation(paginatedSnapSpring) {
                offset = snapped
            }
            return
        }

        if direction * velocity > 0 && timeDelta < 0.5 {
            velocity = (velocity + direction * baseScrollSpeed) * acceleration
        } else {
            velocity = direction * baseScrollSpeed
        }

        velocity = min(maxVelocity, max(-maxVelocity, velocity))

        withAnimation(momentumSpring) {
            offset = clamp(offset + velocity)
        }
    }

    private func startMomentumTimer() {
        momentumTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let isIdle = abs(self.velocity) <= 0.1
                let sleepNanos = isIdle ? self.idleFrameNanos : self.activeFrameNanos
                try? await Task.sleep(nanoseconds: sleepNanos)

                let timeSinceLastScroll = CACurrentMediaTime() - self.lastScrollTime
                if timeSinceLastScroll > 0.1 {
                    let clamped = self.clamp(self.offset)
                    if clamped != self.offset {
                        self.velocity = 0
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                            self.offset = clamped
                        }
                    } else if abs(self.velocity) > 0.1 {
                        self.velocity *= self.deceleration
                        withAnimation(self.momentumSpring) {
                            self.offset += self.velocity
                        }
                    }
                }
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    nonisolated(unsafe) static var orientationLock = UIInterfaceOrientationMask.portrait

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }
}

extension ScrollTextView.ReadableItem {
    var usesWideHorizontalPadding: Bool {
        switch self {
        case .image, .video, .code:
            return true
        case .title, .byline, .paragraph, .richParagraph, .subheading, .listItem, .blockquote, .divider, .callout, .paragraphWithFootnotes, .chapterTOC:
            return false
        }
    }
}

struct ArticleImageView: View {
    let url: URL
    let alt: String?
    let caption: String?

    @EnvironmentObject private var settings: ReaderSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.2))) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                case .failure:
                    placeholder
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: 24, weight: .light))
                                .foregroundColor(.gray.opacity(0.4))
                        }
                default:
                    placeholder
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: settings.captionSize, weight: .regular, design: settings.fontFamily.design).italic())
                    .foregroundColor(.gray.opacity(0.65))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                    .padding(.horizontal, 4)
            }
        }
        .accessibilityLabel(alt ?? caption ?? "Image")
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Color.white.opacity(0.04))
    }
}

struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ParagraphPositionKey: PreferenceKey {
    typealias Value = [Int: CGRect]

    static let defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return CGSize(width: proposal.width ?? 0, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)

        for row in result.rows {
            for item in row {
                let position = CGPoint(
                    x: bounds.minX + item.x,
                    y: bounds.minY + item.y
                )

                item.subview.place(
                    at: position,
                    proposal: ProposedViewSize(item.size)
                )
            }
        }
    }

    struct FlowResult {
        var height: CGFloat = 0
        var rows: [[Item]] = []

        struct Item {
            let subview: LayoutSubview
            var size: CGSize
            var x: CGFloat
            var y: CGFloat
        }

        init(in width: CGFloat, subviews: LayoutSubviews, spacing: CGFloat) {
            var currentX: CGFloat = 0
            var currentRow: [Item] = []
            var currentY: CGFloat = 0
            var maxRowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                if currentX + size.width > width && !currentRow.isEmpty {
                    let rowWidth = currentX - spacing
                    let leftPadding = (width - rowWidth) / 2
                    for index in currentRow.indices {
                        currentRow[index].x += leftPadding
                    }

                    rows.append(currentRow)
                    currentRow = []
                    currentX = 0
                    currentY += maxRowHeight + spacing
                    maxRowHeight = 0
                }

                currentRow.append(Item(
                    subview: subview,
                    size: size,
                    x: currentX,
                    y: currentY
                ))

                currentX += size.width + spacing
                maxRowHeight = max(maxRowHeight, size.height)
            }

            if !currentRow.isEmpty {
                let rowWidth = currentX - spacing
                let leftPadding = (width - rowWidth) / 2
                for index in currentRow.indices {
                    currentRow[index].x += leftPadding
                }

                rows.append(currentRow)
                currentY += maxRowHeight
            }

            height = currentY
        }
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

struct AccentedQuoteView: View {
    let text: String
    let barOpacity: Double
    let textWhite: Double
    let hasBackground: Bool

    @EnvironmentObject private var settings: ReaderSettings

    init(text: String, barOpacity: Double = 0.25, textWhite: Double = 0.78, hasBackground: Bool = false) {
        self.text = text
        self.barOpacity = barOpacity
        self.textWhite = textWhite
        self.hasBackground = hasBackground
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.white.opacity(barOpacity))
                .frame(width: 3)

            Text(text)
                .font(.system(size: settings.blockquoteSize, weight: .regular, design: settings.fontFamily.design).italic())
                .foregroundColor(Color(white: textWhite))
                .lineSpacing(settings.lineSpacingPt(for: settings.blockquoteSize))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, hasBackground ? 12 : 0)
        .padding(.vertical, hasBackground ? 14 : 0)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(hasBackground ? 0.06 : 0))
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChapterTOCView: View {
    let entries: [String]

    @EnvironmentObject private var settings: ReaderSettings

    private static let linkColor = Color(red: 0.4, green: 0.6, blue: 0.9)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                Text(entry)
                    .font(.system(size: settings.paragraphSize, weight: .regular, design: settings.fontFamily.design))
                    .foregroundColor(Self.linkColor)
                    .lineSpacing(settings.lineSpacingPt(for: settings.paragraphSize))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if index < entries.count - 1 {
                    Divider()
                        .opacity(0.12)
                        .padding(.vertical, 4)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
    }
}

struct FootnoteParagraphView: View {
    let text: String
    let footnotes: [ScrollTextView.FootnoteRef]
    @Binding var activeFootnote: String?

    @EnvironmentObject private var settings: ReaderSettings

    var body: some View {
        Text(buildAttributedString())
            .lineSpacing(settings.lineSpacingPt(for: settings.paragraphSize))
            .fixedSize(horizontal: false, vertical: true)
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "footnote", let marker = url.host() {
                    if let fn = footnotes.first(where: { $0.marker == marker }) {
                        activeFootnote = fn.content
                    }
                }
                return .handled
            })
    }

    private func buildAttributedString() -> AttributedString {
        let footnoteMarkers = Set(footnotes.map { $0.marker })
        let pattern = "\\[(\\d+)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return styledPlain(text)
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        if matches.isEmpty {
            return styledPlain(text)
        }

        var result = AttributedString()
        var lastEnd = 0

        for match in matches {
            let matchRange = match.range
            let markerRange = match.range(at: 1)
            let marker = nsText.substring(with: markerRange)

            if matchRange.location > lastEnd {
                let before = nsText.substring(with: NSRange(location: lastEnd, length: matchRange.location - lastEnd))
                result.append(styledPlain(before))
            }

            if footnoteMarkers.contains(marker) {
                var markerStr = AttributedString("[\(marker)]")
                markerStr.font = .system(size: settings.paragraphSize * 0.7, weight: .medium, design: settings.fontFamily.design)
                markerStr.foregroundColor = Color(red: 0.55, green: 0.7, blue: 0.9)
                markerStr.baselineOffset = settings.paragraphSize * 0.3
                markerStr.link = URL(string: "footnote://\(marker)")
                result.append(markerStr)
            } else {
                result.append(styledPlain("[\(marker)]"))
            }

            lastEnd = matchRange.location + matchRange.length
        }

        if lastEnd < nsText.length {
            let remaining = nsText.substring(from: lastEnd)
            result.append(styledPlain(remaining))
        }

        return result
    }

    private func styledPlain(_ str: String) -> AttributedString {
        var attr = AttributedString(str)
        attr.font = .system(size: settings.paragraphSize, weight: .regular, design: settings.fontFamily.design)
        attr.foregroundColor = Color(white: 0.92)
        return attr
    }
}

struct FootnoteOverlay: View {
    let text: String
    let onDismiss: () -> Void

    @EnvironmentObject private var settings: ReaderSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Footnote")
                    .font(.system(size: settings.paragraphSize - 2, weight: .semibold, design: settings.fontFamily.design))
                    .foregroundColor(Color(white: 0.7))
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(Color(white: 0.5))
                }
            }
            Text(text)
                .font(.system(size: settings.paragraphSize - 1, weight: .regular, design: settings.fontFamily.design))
                .foregroundColor(Color(white: 0.88))
                .lineSpacing(settings.lineSpacingPt(for: settings.paragraphSize - 1))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 0.15))
                .shadow(color: .black.opacity(0.5), radius: 10, y: -4)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .onTapGesture {
            onDismiss()
        }
    }
}

struct CodeBlockView: View {
    let text: String

    @EnvironmentObject private var settings: ReaderSettings

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(size: settings.codeSize, design: .monospaced))
                .foregroundColor(Color(white: 0.88))
                .padding(14)
                .fixedSize(horizontal: true, vertical: false)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.10, green: 0.10, blue: 0.10))
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct VideoEmbedView: View {
    let videoURL: URL
    let thumbnailURL: URL?
    let provider: VideoProvider

    @State private var sheetURL: IdentifiableURL?

    var body: some View {
        Button {
            sheetURL = IdentifiableURL(url: videoURL)
        } label: {
            ZStack {
                Group {
                    if let thumbnailURL {
                        AsyncImage(url: thumbnailURL, transaction: Transaction(animation: .easeIn(duration: 0.2))) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            default:
                                placeholder
                            }
                        }
                        .clipped()
                    } else {
                        placeholder
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)

                LinearGradient(
                    colors: [.black.opacity(0.0), .black.opacity(0.35)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                Image(systemName: "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(18)
                    .background(Circle().fill(Color.black.opacity(0.55)))
                    .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityLabel(provider == .youtube ? "Play YouTube video" : "Play video")
        }
        .buttonStyle(.plain)
        .sheet(item: $sheetURL) { item in
            SafariView(url: item.url)
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Color.white.opacity(0.04))
            .overlay {
                Image(systemName: "video")
                    .font(.system(size: 24, weight: .light))
                    .foregroundColor(.gray.opacity(0.4))
            }
    }
}

struct ShareButton: View {
    let article: Article

    var body: some View {
        Button {
            presentShareSheet()
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }

    private func presentShareSheet() {
        var items: [Any] = []
        let trimmedTitle = article.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { items.append(trimmedTitle) }
        if let url = article.link { items.append(url) }
        guard !items.isEmpty else { return }

        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        guard let scene = activeScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
              let root = window.rootViewController else { return }

        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = root.view
        activity.popoverPresentationController?.sourceRect = CGRect(
            x: root.view.bounds.midX,
            y: root.view.bounds.midY,
            width: 0,
            height: 0
        )
        activity.popoverPresentationController?.permittedArrowDirections = []

        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(activity, animated: true)
    }
}

struct ReaderSettingsSheet: View {
    @ObservedObject var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("Reader")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
            }

            sizeSection
            optionSection("Font", options: ReaderFontFamily.allCases, selection: $settings.fontFamily, label: \.label)
            optionSection("Line spacing", options: ReaderLineSpacing.allCases, selection: $settings.lineSpacing, label: \.label)
            optionSection("Margins", options: ReaderMargins.allCases, selection: $settings.margins, label: \.label)
            optionSection("Scroll", options: ReaderScrollMode.allCases, selection: $settings.scrollMode, label: \.label)
            optionSection("Control", options: ReaderScrollControl.allCases, selection: $settings.scrollControl, label: \.label)
            aiQuestionsToggle
            brightnessSection

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.ignoresSafeArea())
        .presentationDetents([.height(640)])
        .presentationBackground(Color.black)
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Size", trailing: "\(Int(settings.fontSize))pt")
            HStack(spacing: 12) {
                Text("A")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.45))
                Slider(value: $settings.fontSize, in: 14...28, step: 1)
                    .tint(.white.opacity(0.9))
                Text("A")
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.45))
            }
        }
    }

    private func optionSection<Option: Hashable & Identifiable>(
        _ title: String,
        options: [Option],
        selection: Binding<Option>,
        label: KeyPath<Option, String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(title)
            segmentedControl(options: options, selection: selection, label: label)
        }
    }

    private var aiQuestionsToggle: some View {
        HStack {
            Text("AI Questions")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.45))
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer()
            Toggle("", isOn: $settings.showAIQuestions)
                .labelsHidden()
                .tint(.white.opacity(0.6))
        }
    }

    private var brightnessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Brightness")
            HStack(spacing: 12) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.45))
                Slider(value: $settings.dimLevel, in: 0...0.7)
                    .tint(.white.opacity(0.9))
                Image(systemName: "moon.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.45))
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, trailing: String? = nil) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.45))
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
    }

    private func segmentedControl<Option: Hashable & Identifiable>(
        options: [Option],
        selection: Binding<Option>,
        label: KeyPath<Option, String>
    ) -> some View {
        HStack(spacing: 6) {
            ForEach(options) { option in
                let isSelected = selection.wrappedValue == option
                Button {
                    selection.wrappedValue = option
                } label: {
                    Text(option[keyPath: label])
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isSelected ? .black : .white.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(isSelected ? Color.white.opacity(0.92) : Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private func buildHighlightDisplayText(
    base: NSAttributedString,
    highlights: [Highlight],
    selectionRange: NSRange? = nil
) -> NSAttributedString {
    let mutable = NSMutableAttributedString(attributedString: base)
    for h in highlights {
        let range = NSRange(location: h.startOffset, length: h.endOffset - h.startOffset)
        guard range.location >= 0, NSMaxRange(range) <= mutable.length else { continue }
        mutable.addAttribute(.backgroundColor, value: UIColor.yellow.withAlphaComponent(0.3), range: range)
    }
    if let sel = selectionRange, sel.length > 0, sel.location >= 0, NSMaxRange(sel) <= mutable.length {
        mutable.addAttribute(.backgroundColor, value: UIColor.yellow.withAlphaComponent(0.25), range: sel)
    }
    return mutable
}

struct HighlightableTextView: UIViewRepresentable {
    let text: String
    let attributedText: NSAttributedString
    let highlights: [Highlight]
    let onHighlightCreated: (String, Int, Int) -> Void
    let onHighlightRemoved: (UUID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = false
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.setContentHuggingPriority(.required, for: .vertical)
        tv.setContentCompressionResistancePriority(.required, for: .vertical)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        tv.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tv.addGestureRecognizer(tap)

        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let c = context.coordinator
        c.baseAttributedText = attributedText
        c.highlights = highlights
        c.text = text
        c.onHighlightCreated = onHighlightCreated
        c.onHighlightRemoved = onHighlightRemoved
        if c.isDragging { return }
        tv.attributedText = buildHighlightDisplayText(base: attributedText, highlights: highlights)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingCompressedSize.width
        let size = uiView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }

    @MainActor
    final class Coordinator: NSObject {
        var baseAttributedText = NSAttributedString()
        var highlights: [Highlight] = []
        var text: String = ""
        var onHighlightCreated: ((String, Int, Int) -> Void)?
        var onHighlightRemoved: ((UUID) -> Void)?
        var isDragging = false
        private var dragStart: Int?

        private func charIndex(at point: CGPoint, in tv: UITextView) -> Int {
            let layoutManager = tv.layoutManager
            let textContainer = tv.textContainer
            let inset = tv.textContainerInset
            let p = CGPoint(x: point.x - inset.left, y: point.y - inset.top)
            let idx = layoutManager.characterIndex(for: p, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
            return min(idx, (tv.text ?? "").count)
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let tv = g.view as? UITextView else { return }
            let pt = g.location(in: tv)

            switch g.state {
            case .began:
                isDragging = true
                dragStart = charIndex(at: pt, in: tv)
            case .changed:
                guard let start = dragStart else { return }
                let current = charIndex(at: pt, in: tv)
                let loc = min(start, current)
                let len = abs(current - start)
                tv.attributedText = buildHighlightDisplayText(
                    base: baseAttributedText,
                    highlights: highlights,
                    selectionRange: NSRange(location: loc, length: len)
                )
            case .ended:
                guard let start = dragStart else { return }
                let end = charIndex(at: pt, in: tv)
                let loc = min(start, end)
                let len = abs(end - start)
                if len > 0 {
                    let nsText = (text as NSString)
                    let range = NSRange(location: loc, length: min(len, nsText.length - loc))
                    if NSMaxRange(range) <= nsText.length {
                        let selectedText = nsText.substring(with: range)
                        onHighlightCreated?(selectedText, loc, loc + range.length)
                    }
                }
                isDragging = false
                dragStart = nil
                tv.attributedText = buildHighlightDisplayText(base: baseAttributedText, highlights: highlights)
            default:
                isDragging = false
                dragStart = nil
                tv.attributedText = buildHighlightDisplayText(base: baseAttributedText, highlights: highlights)
            }
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let tv = g.view as? UITextView else { return }
            let pt = g.location(in: tv)
            let idx = charIndex(at: pt, in: tv)

            for h in highlights where idx >= h.startOffset && idx < h.endOffset {
                onHighlightRemoved?(h.id)
                return
            }
        }
    }
}

#Preview {
    ScrollTextView()
        .environment(HighlightStore())
}
