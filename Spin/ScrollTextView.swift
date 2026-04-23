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
    // Hidden for now; keep the view and model in place to re-enable later.
    @State private var showQuestion: Bool = false
    @State private var controlPanelHeight: CGFloat = 0
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
    private let topPadding: CGFloat = 20
    private let backButtonTopPadding: CGFloat = 80
    let maxTags = 5
    private let pageAnimation: Animation = .spring(response: 0.3, dampingFraction: 0.88)

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

    var body: some View {
        GeometryReader { geometry in
            let panelTopGap: CGFloat = 8
            let panelBottomInset: CGFloat = 24
            let reservedBottomSpace = controlPanelHeight + panelTopGap + panelBottomInset
            let scrollViewHeight = max(0, geometry.size.height - reservedBottomSpace)
            ZStack(alignment: .top) {
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
                .frame(maxWidth: .infinity, alignment: .top)
                .scrollDisabled(true)
                .onPreferenceChange(ParagraphPositionKey.self) { positions in
                    // Viewport is the unblocked area above the panel — content under the panel is visually refracted by the glass but doesn't count as "visible" for auto-highlight.
                    let viewport = CGRect(x: 0, y: 0, width: geometry.size.width, height: scrollViewHeight)
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
                    let currentOffset = scrollState.offset
                    let contentBounds = positions.values.map { frame in
                        (minY: Double(frame.minY) - currentOffset,
                         maxY: Double(frame.maxY) - currentOffset)
                    }
                    scrollState.setItemBounds(contentBounds)
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
            }

            // Top fade: scrolled content dissolves into black before reaching the status bar / top controls.
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.6),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 100)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)

            ControlPanel(
                highlightAnimating: autoHighlightAnimating,
                onHighlight: {
                    cycleHighlightForTopVisibleParagraph(
                        viewportWidth: geometry.size.width,
                        scrollViewHeight: scrollViewHeight,
                        topFadeHeight: 0
                    )
                    flashAutoHighlightFeedback()
                },
                onHighlightSwipeDown: {
                    extendHighlightForTopVisibleParagraph(
                        viewportWidth: geometry.size.width,
                        scrollViewHeight: scrollViewHeight,
                        topFadeHeight: 0
                    )
                    flashAutoHighlightFeedback()
                },
                onTrackpadPageUp: {
                    hideTopBarIfNeeded()
                    withAnimation(pageAnimation) {
                        scrollState.goToPreviousPage()
                    }
                },
                onTrackpadPageDown: {
                    hideTopBarIfNeeded()
                    if scrollState.isAtBottom {
                        advanceToNextChapter()
                        return
                    }
                    withAnimation(pageAnimation) {
                        scrollState.goToNextPage()
                    }
                    spinCount += 1
                    if spinCount >= 2 {
                        spinCount = 0
                        handleAnalysisRequest()
                    }
                },
                tags: readerSettings.showAIQuestions ? Array(tags.prefix(maxTags)) : [],
                showQuestion: showQuestion && readerSettings.showAIQuestions,
                currentQuestion: currentQuestion,
                isLoadingQuestion: isLoadingQuestion,
                onQuestionTap: {
                    if let url = perplexityURL(for: currentQuestion) {
                        explainerURL = IdentifiableURL(url: url)
                    }
                },
                onTagTap: { tag in
                    if let url = perplexityURL(for: tag) {
                        explainerURL = IdentifiableURL(url: url)
                    }
                }
            )
            .background(
                GeometryReader { geo in
                    // Panel height drives the scroll viewport so reading content never sits behind the panel.
                    Color.clear.preference(key: ControlPanelHeightKey.self, value: geo.size.height)
                }
            )
            .padding(.horizontal, 34)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .onPreferenceChange(ControlPanelHeightKey.self) { value in
                if abs(value - controlPanelHeight) > 0.5 {
                    controlPanelHeight = value
                }
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
        .sheet(item: $explainerURL) { item in
            SafariView(url: item.url)
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

