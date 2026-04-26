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

    @StateObject var scrollState = ScrollState()
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
    @State var selectedHighlightColor: HighlightColorChoice = .yellow
    // Hidden for now; keep the view and model in place to re-enable later.
    @State private var showQuestion: Bool = false
    @State private var controlPanelHeight: CGFloat = 0
    // The highlight key moves a single active selection sentence-by-sentence through the text.
    @State var autoHighlightSelection: AutoHighlightSelection?
    @State var paragraphFrames: [Int: CGRect] = [:]
    // Last content-space frames fed to the Paginator. Used to skip re-measurement during
    // page-flip animations, where the preference key refires but content frames are unchanged.
    @State var lastPaginationFrames: [Int: CGRect] = [:]
    @State var lastPaginationViewportHeight: Double = 0
    @State var lastPaginationViewportWidth: Double = 0

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
    // Editorial whitespace between the status bar/safe area and the first line of body text.
    private let editorialTopPadding: CGFloat = 6
    // Height of the top-bar black band when the nav buttons are showing. Covers status bar and
    // the 44pt button row, preventing text from ghosting under the buttons.
    private let topBarBandHeight: CGFloat = 50
    // Gap between the text viewport's bottom and the top of the control panel so no text sits
    // behind the liquid-glass material.
    private let viewportToPanelGap: CGFloat = 16
    private let panelTopGap: CGFloat = 8
    private let panelBottomInset: CGFloat = 24
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
            // GeometryReader is already inside the safe area by default, so y=0 in its
            // coordinate space is flush against the bottom of the status bar.
            let topInset = editorialTopPadding
            let clippedBottomLineHeight = reservedBottomLineHeight()
            let reservedBottomSpace = controlPanelHeight + panelTopGap + panelBottomInset + viewportToPanelGap
            let viewportHeight = max(0, geometry.size.height - topInset - reservedBottomSpace - clippedBottomLineHeight)
            let viewportWidth = geometry.size.width

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
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                    }
                )
                .offset(y: scrollState.offset)
            }
            .coordinateSpace(name: "scroll")
            .frame(width: viewportWidth, height: viewportHeight, alignment: .top)
            .clipped()
            .position(x: viewportWidth / 2, y: topInset + viewportHeight / 2)
            .scrollDisabled(true)
            .onPreferenceChange(ParagraphPositionKey.self) { positions in
                let viewport = CGRect(x: 0, y: 0, width: viewportWidth, height: viewportHeight)
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
                recomputePageStarts(
                    positions: positions,
                    viewportHeight: Double(viewportHeight),
                    viewportWidth: Double(viewportWidth)
                )
            }
            .onPreferenceChange(ContentHeightKey.self) { _ in
                if isLoadingNextChapter {
                    isLoadingNextChapter = false
                }
            }
            .onChange(of: readerSettings.fontSize) { _, _ in
                recomputePageStartsWithCurrentFrames(
                    viewportHeight: Double(viewportHeight),
                    viewportWidth: Double(viewportWidth)
                )
            }
            .onChange(of: readerSettings.lineSpacing) { _, _ in
                recomputePageStartsWithCurrentFrames(
                    viewportHeight: Double(viewportHeight),
                    viewportWidth: Double(viewportWidth)
                )
            }
            .onChange(of: readerSettings.margins) { _, _ in
                recomputePageStartsWithCurrentFrames(
                    viewportHeight: Double(viewportHeight),
                    viewportWidth: Double(viewportWidth)
                )
            }
            .onChange(of: readerSettings.fontFamily) { _, _ in
                recomputePageStartsWithCurrentFrames(
                    viewportHeight: Double(viewportHeight),
                    viewportWidth: Double(viewportWidth)
                )
            }
            // Viewport shrinks when the control panel reports its real height after first render.
            // Item frames don't move in "scroll" space, so the preference key doesn't re-fire;
            // trigger an explicit recompute against the new viewport height.
            .onChange(of: controlPanelHeight) { _, _ in
                recomputePageStartsWithCurrentFrames(
                    viewportHeight: Double(viewportHeight),
                    viewportWidth: Double(viewportWidth)
                )
            }
            .onChange(of: showTopBar) { _, _ in
                recomputePageStartsWithCurrentFrames(
                    viewportHeight: Double(viewportHeight),
                    viewportWidth: Double(viewportWidth)
                )
            }

            ControlPanel(
                isHighlightMode: autoHighlightSelection != nil,
                selectedHighlightColor: selectedHighlightColor,
                onHighlight: {
                    if autoHighlightSelection != nil {
                        confirmPendingHighlight()
                    } else {
                        let update = cycleHighlightForTopVisibleParagraph(
                            viewportWidth: geometry.size.width,
                            scrollViewHeight: viewportHeight,
                            topFadeHeight: 0
                        )
                        handleAutoHighlightUpdate(update)
                        updatePendingHighlightColor(selectedHighlightColor)
                    }
                },
                onHighlightColorSelected: { color in
                    selectedHighlightColor = color
                    updatePendingHighlightColor(color)
                },
                onCancelHighlight: {
                    cancelPendingHighlight()
                },
                onTrackpadPageUp: {
                    if autoHighlightSelection != nil {
                        handleAutoHighlightUpdate(cycleHighlightForTopVisibleParagraph(
                            viewportWidth: geometry.size.width,
                            scrollViewHeight: viewportHeight,
                            topFadeHeight: 0
                        ))
                        return
                    }
                    hideTopBarIfNeeded()
                    withAnimation(pageAnimation) {
                        scrollState.goToPreviousPage()
                    }
                },
                onTrackpadPageDown: {
                    if autoHighlightSelection != nil {
                        handleAutoHighlightUpdate(previousHighlightForTopVisibleParagraph(
                            viewportWidth: geometry.size.width,
                            scrollViewHeight: viewportHeight,
                            topFadeHeight: 0
                        ))
                        return
                    }
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
                onLearnMoreTap: {
                    openPerplexity(for: .learnMore)
                },
                onFactCheckTap: {
                    openPerplexity(for: .factCheck)
                },
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
                    Color.black
                        .frame(height: topBarBandHeight)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .ignoresSafeArea(edges: .top)
                        .allowsHitTesting(false)

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white.opacity(0.55))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .position(x: 30, y: 24)

                    Button {
                        showHighlightsList = true
                    } label: {
                        Image(systemName: "highlighter")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white.opacity(0.55))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .position(x: geometry.size.width - 74, y: 24)

                    Button {
                        showReaderSettings = true
                    } label: {
                        Image(systemName: "textformat.size")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white.opacity(0.55))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .position(x: geometry.size.width - 30, y: 24)
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
        .statusBar(hidden: !showTopBar)
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

    func presentExplainer(for query: String) {
        guard let url = perplexityURL(for: query) else { return }
        explainerURL = IdentifiableURL(url: url)
    }

    private func hideTopBarIfNeeded() {
        guard showTopBar else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            showTopBar = false
        }
    }

    private func reservedBottomLineHeight() -> CGFloat {
        let sample = nsStyledText("Ag", size: readerSettings.paragraphSize, weight: .regular)
        if let line = Paginator.measureLines(for: sample, width: 1000).first {
            return CGFloat(line.maxY - line.minY)
        }
        return readerSettings.paragraphSize * 1.2
            + readerSettings.lineSpacingPt(for: readerSettings.paragraphSize)
    }

    private func handleAutoHighlightUpdate(_ update: AutoHighlightUpdate) {
        guard case .changed(let pageTurn) = update else { return }
        switch pageTurn {
        case .next:
            hideTopBarIfNeeded()
            if scrollState.isAtBottom {
                advanceToNextChapter()
            } else {
                withAnimation(pageAnimation) {
                    scrollState.goToNextPage()
                }
            }
        case .previous:
            hideTopBarIfNeeded()
            withAnimation(pageAnimation) {
                scrollState.goToPreviousPage()
            }
        case .none:
            break
        }
    }
}

