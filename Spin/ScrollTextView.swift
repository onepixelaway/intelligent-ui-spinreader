import SwiftUI
import UIKit
import CoreHaptics
import NaturalLanguage
@preconcurrency import OpenAI
import QuartzCore
import SafariServices

struct ScrollTextView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(HighlightStore.self) var highlightStore

    @StateObject private var scrollState = ScrollState()
    @StateObject var readerSettings = ReaderSettings()
    @State private var showTopGradient: Bool = false
    @State private var showTopBar: Bool = true
    @State var visibleParagraphs: [Int] = []
    @State var spinCount: Int = 0
    @State var lastAnalyzedText: String = ""
    @State var tags: [String] = []
    @State var currentQuestion: String = ""
    @State var isLoadingQuestion: Bool = false
    @State private var explainerURL: IdentifiableURL?
    @State var analysisTask: Task<Void, Never>?
    @State private var showReaderSettings: Bool = false
    @State private var showHighlightsList: Bool = false
    @State var activeFootnote: String? = nil
    @State var isLoadingNextChapter: Bool = false
    @State private var autoHighlightAnimating: Bool = false
    // Keyed by `items` index. Stable because new chapters only append; reordering or in-place replacement would corrupt cycle state.
    @State var autoHighlightCycleStep: [Int: Int] = [:]
    @State var autoHighlightIDs: [Int: [UUID]] = [:]
    @State var autoHighlightStartOffset: [Int: Int] = [:]
    @State var autoHighlightExtendCount: [Int: Int] = [:]
    @State var paragraphFrames: [Int: CGRect] = [:]

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
        case divider
        case callout(String)
        case paragraphWithFootnotes(text: String, footnotes: [FootnoteRef])
        case chapterTOC([String])
    }

    @State var items: [ReadableItem]
    let chapters: [EpubChapter]
    @State var chapterIndex: Int
    private let showsBackButton: Bool
    let contentID: String
    let bookID: String?
    // Must stay same length/order as `items`. contentIDForItem(at:) silently falls back on mismatch.
    @State var itemContentIDs: [String] = []
    let viewportHeightFraction: CGFloat = 0.60
    private let topPadding: CGFloat = 20
    private let backButtonTopPadding: CGFloat = 64
    let maxTags = 5
    private let topGradientThreshold: CGFloat = 200
    private let topFadeFraction: CGFloat = 0.15
    private let highlightSwipeMinDistance: CGFloat = 20
    private let highlightSwipeActivationDY: CGFloat = 30

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
        self.contentID = cid
        self.bookID = bookID
        _itemContentIDs = State(initialValue: Array(repeating: cid, count: built.count))
    }

    private struct TagView: View {
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
                        let visibleHeight = scrollViewHeight * viewportHeightFraction
                        let viewport = CGRect(x: 0, y: 0, width: geometry.size.width, height: visibleHeight)
                        let newVisible = positions
                            .filter { $0.value.intersects(viewport) }
                            .map { $0.key }
                            .sorted()
                        if newVisible != visibleParagraphs {
                            visibleParagraphs = newVisible
                        }
                        if positions != paragraphFrames {
                            paragraphFrames = positions
                        }
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
                .opacity((showsBackButton && showTopBar) || showTopGradient ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: showTopBar)
                .animation(.easeInOut(duration: 0.3), value: showTopGradient)
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.075)
            }

            TrackpadScrollView(
                onDrag: { delta in
                    hideTopBarIfNeeded()
                    if delta < 0 && scrollState.isAtBottom {
                        advanceToNextChapter()
                        return
                    }
                    scrollState.applyDirectDelta(delta)
                    showTopGradient = abs(scrollState.offset) > topGradientThreshold
                },
                onFlick: { direction in
                    hideTopBarIfNeeded()
                    if direction < 0 && scrollState.isAtBottom {
                        advanceToNextChapter()
                        return
                    }
                    scrollState.handleScroll(direction: direction, paginatedChunk: readerSettings.paginatedChunkHeight)
                    showTopGradient = abs(scrollState.offset) > topGradientThreshold
                    spinCount += 1
                    if spinCount >= 2 {
                        spinCount = 0
                        handleAnalysisRequest()
                    }
                },
                onRelease: {
                    scrollState.snapToBoundsIfNeeded()
                }
            )
            .frame(width: geometry.size.width * 0.3, height: geometry.size.width * 0.3)
            .position(x: geometry.size.width / 2, y: geometry.size.height * 0.76)

            if !visibleParagraphs.isEmpty {
                let trackpadLeadingX = geometry.size.width * 0.5 - geometry.size.width * 0.3 / 2
                let buttonTrackpadGap: CGFloat = 54
                let topFadeHeight = geometry.size.height * topFadeFraction
                Button {
                    cycleHighlightForTopVisibleParagraph(
                        viewportWidth: geometry.size.width,
                        scrollViewHeight: scrollViewHeight,
                        topFadeHeight: topFadeHeight
                    )
                    flashAutoHighlightFeedback()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.06))
                            .frame(width: 52, height: 52)
                        Image(systemName: autoHighlightAnimating ? "checkmark" : "highlighter")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundColor(.white.opacity(0.75))
                            .padding(14)
                    }
                    .scaleEffect(autoHighlightAnimating ? 1.1 : 1.0)
                }
                .highPriorityGesture(
                    DragGesture(minimumDistance: highlightSwipeMinDistance)
                        .onEnded { value in
                            let dy = value.translation.height
                            let dx = value.translation.width
                            guard dy > highlightSwipeActivationDY, dy > abs(dx) else { return }
                            extendHighlightForTopVisibleParagraph(
                                viewportWidth: geometry.size.width,
                                scrollViewHeight: scrollViewHeight,
                                topFadeHeight: topFadeHeight
                            )
                            flashAutoHighlightFeedback()
                        }
                )
                .position(x: trackpadLeadingX - buttonTrackpadGap, y: geometry.size.height * 0.76)
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
                Group {
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
                    .position(x: geometry.size.width - 74, y: 30)

                    Button {
                        showReaderSettings = true
                    } label: {
                        Image(systemName: "textformat.size")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white.opacity(0.55))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .position(x: geometry.size.width - 30, y: 30)
                }
                .opacity(showTopBar ? 1 : 0)
                .allowsHitTesting(showTopBar)
                .animation(.easeInOut(duration: 0.2), value: showTopBar)

                if !showTopBar {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: geometry.size.height * 0.15)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showTopBar = true
                            }
                        }
                        .position(x: geometry.size.width / 2, y: geometry.size.height * 0.075)
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

    private func hideTopBarIfNeeded() {
        guard showTopBar else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            showTopBar = false
        }
    }

    private func flashAutoHighlightFeedback() {
        withAnimation(.easeInOut(duration: 0.15)) {
            autoHighlightAnimating = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeInOut(duration: 0.15)) {
                autoHighlightAnimating = false
            }
        }
    }
}

