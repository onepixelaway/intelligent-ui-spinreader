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
    @StateObject var speechCoordinator = ReaderSpeechCoordinator()
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
    @State var debugPlaybackPagingStatus: String = "idle"
    @State var activeFootnote: String? = nil
    @State var isLoadingNextChapter: Bool = false
    @State var selectedHighlightColor: HighlightColorChoice = .yellow
    @State var selectedHighlightEmoji: HighlightEmojiChoice? = nil
    // Hidden for now; keep the view and model in place to re-enable later.
    @State private var showQuestion: Bool = false
    @State private var measuredPanelHeight: CGFloat = 0
    @State private var frozenPanelHeight: CGFloat = 0
    // The highlight key moves a single active selection sentence-by-sentence through the text.
    @State var autoHighlightSelection: AutoHighlightSelection?
    @State var paragraphFrames: [Int: CGRect] = [:]
    // Authoritative content-space frames for pagination and highlight geometry.
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
    // Must stay same length/order as `items`. Each entry scopes persisted highlights to one rendered item.
    @State var itemContentIDs: [String] = []
    // Editorial whitespace between the status bar/safe area and the first line of body text.
    private let editorialTopPadding: CGFloat = 6
    private let viewportTopOffset: CGFloat = 15
    // Height of the top-bar black band when the nav buttons are showing. Covers status bar and
    // the 44pt button row, preventing text from ghosting under the buttons.
    private let topBarBandHeight: CGFloat = 50
    // Gap between the text viewport's bottom and the top of the control panel so no text sits
    // behind the liquid-glass material.
    private let viewportToPanelGap: CGFloat = 8
    private let panelTopGap: CGFloat = 4
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
        let cid = Self.chapterContentID(bookID: bookID, xhtmlPath: chapter.xhtmlPath)
        _items = State(initialValue: built)
        self.chapters = chapters
        _chapterIndex = State(initialValue: startingIndex)
        self.showsBackButton = true
        self.contentID = cid
        self.bookID = bookID
        _itemContentIDs = State(initialValue: Self.itemContentIDs(for: built, chapterContentID: cid))
    }

    static func chapterContentID(bookID: String, xhtmlPath: String) -> String {
        "\(bookID):\(xhtmlPath)"
    }

    static func itemContentIDs(for items: [ReadableItem], chapterContentID: String) -> [String] {
        items.indices.map { "\(chapterContentID)#item-\($0)" }
    }

    var body: some View {
        GeometryReader { geometry in
            // GeometryReader is already inside the safe area by default, so y=0 in its
            // coordinate space is flush against the bottom of the status bar.
            let topInset = editorialTopPadding
            let viewportTop = topInset + viewportTopOffset
            let bottomLineGuard = reservedBottomLineHeight() * 3
            let reservedBottomSpace = frozenPanelHeight + panelTopGap + panelBottomInset + viewportToPanelGap
            let viewportHeight = max(0, geometry.size.height - topInset - reservedBottomSpace - bottomLineGuard)
            let visiblePageHeight = CGFloat(scrollState.visiblePageHeight(for: Double(viewportHeight)))
            let isHighlightMode = autoHighlightSelection != nil
            let activePanelHeight = measuredPanelHeight > 0 ? measuredPanelHeight : frozenPanelHeight
            let highlightSelectionViewportHeight = isHighlightMode
                ? min(
                    visiblePageHeight,
                    max(
                        0,
                        geometry.size.height
                            - topInset
                            - activePanelHeight
                            - panelTopGap
                            - panelBottomInset
                            - viewportToPanelGap
                            - bottomLineGuard
                    )
                )
                : visiblePageHeight
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
            .frame(width: viewportWidth, height: visiblePageHeight, alignment: .top)
            .clipped()
            .position(x: viewportWidth / 2, y: viewportTop + visiblePageHeight / 2)
            .scrollDisabled(true)
            .onPreferenceChange(ParagraphPositionKey.self) { positions in
                let contentPositions = contentFrames(from: positions)
                updateVisibleParagraphs(
                    positions: contentPositions,
                    viewportWidth: viewportWidth,
                    viewportHeight: visiblePageHeight
                )
                if contentPositions != paragraphFrames {
                    paragraphFrames = contentPositions
                }
                recomputePageStarts(
                    positions: contentPositions,
                    viewportHeight: Double(viewportHeight),
                    viewportWidth: Double(viewportWidth)
                )
            }
            .onChange(of: scrollState.currentPage) { _, _ in
                updateVisibleParagraphs(
                    positions: paragraphFrames,
                    viewportWidth: viewportWidth,
                    viewportHeight: visiblePageHeight
                )
            }
            .onChange(of: scrollState.pageStarts) { _, _ in
                updateVisibleParagraphs(
                    positions: paragraphFrames,
                    viewportWidth: viewportWidth,
                    viewportHeight: visiblePageHeight
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
            // The text viewport is locked to the normal panel height so entering highlight mode
            // never shifts the page. Only normal-mode panel measurement can change pagination.
            .onChange(of: frozenPanelHeight) { _, _ in
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

            let pageBoundaryMaskOverlap: CGFloat = 6
            let hiddenPageTop = max(0, visiblePageHeight - pageBoundaryMaskOverlap)
            let hiddenPageHeight = max(0, viewportHeight - hiddenPageTop)
            if hiddenPageHeight > 0 {
                Color.black
                    .frame(width: viewportWidth, height: hiddenPageHeight)
                    .position(
                        x: viewportWidth / 2,
                        y: viewportTop + hiddenPageTop + hiddenPageHeight / 2
                    )
                    .allowsHitTesting(false)
            }

            ControlPanel(
                isHighlightMode: isHighlightMode,
                selectedHighlightColor: selectedHighlightColor,
                selectedHighlightEmoji: selectedHighlightEmoji,
                onHighlight: {
                    activateOrCommitHighlight(
                        viewportWidth: geometry.size.width,
                        viewportHeight: highlightSelectionViewportHeight
                    )
                },
                onHighlightColorSelected: { color in
                    selectedHighlightColor = color
                    selectedHighlightEmoji = nil
                    updatePendingHighlightColor(color)
                },
                onHighlightEmojiSelected: { emoji in
                    selectedHighlightEmoji = emoji
                    updatePendingHighlightEmoji(emoji)
                },
                onCancelHighlight: {
                    cancelPendingHighlight()
                },
                onTrackpadPageUp: {
                    if isHighlightMode {
                        // In highlight mode the trackpad acts like direct selection movement:
                        // swiping down advances the highlight down the page, which feels natural.
                        selectNextHighlight(
                            viewportWidth: geometry.size.width,
                            viewportHeight: highlightSelectionViewportHeight
                        )
                        return
                    }
                    hideTopBarIfNeeded()
                    withAnimation(pageAnimation) {
                        scrollState.goToPreviousPage()
                    }
                },
                onTrackpadPageDown: {
                    if isHighlightMode {
                        // In highlight mode the trackpad acts like direct selection movement:
                        // swiping up moves the highlight back up the page, which feels natural.
                        selectPreviousHighlight(
                            viewportWidth: geometry.size.width,
                            viewportHeight: highlightSelectionViewportHeight
                        )
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
                isPlaybackSpeaking: speechCoordinator.isSpeaking,
                isPlaybackPaused: speechCoordinator.isPaused,
                isPlaybackPreparing: speechCoordinator.isPreparingPlayback,
                onPlaybackToggle: {
                    let viewport = CGRect(
                        x: 0,
                        y: -CGFloat(scrollState.offset),
                        width: geometry.size.width,
                        height: visiblePageHeight
                    )
                    speechCoordinator.togglePlayback(
                        startingWith: playbackSegments(
                            startingAt: firstVisiblePlaybackLocation(viewport: viewport)
                        )
                    )
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
                    // Normal-mode panel height drives pagination. Highlight-mode panel growth
                    // intentionally overlays the page without changing the text viewport.
                    Color.clear.preference(key: ControlPanelHeightKey.self, value: geo.size.height)
                }
            )
            .padding(.horizontal, 34)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .onPreferenceChange(ControlPanelHeightKey.self) { value in
                if abs(value - measuredPanelHeight) > 0.5 {
                    measuredPanelHeight = value
                }
                if autoHighlightSelection == nil && abs(value - frozenPanelHeight) > 0.5 {
                    frozenPanelHeight = value
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

            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-SpinPlaybackPagingUITest") {
                VStack(spacing: 10) {
                    Text("PlaybackPage \(scrollState.currentPage)")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.75))
                        .clipShape(Capsule())
                        .accessibilityIdentifier("playback-page-label")

                    Text(debugPlaybackPagingStatus)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.75))
                        .clipShape(Capsule())
                        .accessibilityIdentifier("playback-debug-status")

                    Button("Simulate Next Page Word") {
                        debugSimulatePlaybackWordOnNextPage()
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white)
                    .clipShape(Capsule())
                    .accessibilityIdentifier("simulate-next-page-word-button")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 64)
                .allowsHitTesting(true)
            }
            #endif
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
        .sheet(isPresented: Binding(
            get: { speechCoordinator.kokoroPreparation.isPresenting },
            set: { newValue in
                if !newValue && speechCoordinator.kokoroPreparation != .idle {
                    speechCoordinator.cancelKokoroPreparation()
                }
            }
        )) {
            KokoroDownloadSheet(coordinator: speechCoordinator)
                .interactiveDismissDisabled(true)
                .presentationDetents([.medium])
        }
        .onChange(of: speechCoordinator.highlight) { _, highlight in
            guard let highlight else {
                debugPlaybackPagingStatus = "no-highlight"
                return
            }
            let viewportWidth = CGFloat(lastPaginationViewportWidth)
            let paginationViewportHeight = CGFloat(lastPaginationViewportHeight)
            guard viewportWidth > 0, paginationViewportHeight > 0 else {
                debugPlaybackPagingStatus = "bad-viewport \(Int(viewportWidth))x\(Int(paginationViewportHeight))"
                return
            }
            let pageStartY = -CGFloat(scrollState.offset)
            let layoutViewport = CGRect(
                x: 0,
                y: pageStartY,
                width: viewportWidth,
                height: paginationViewportHeight
            )
            if let targetPage = playbackHighlightTargetPage(highlight, viewport: layoutViewport) {
                withAnimation(pageAnimation) {
                    scrollState.goToPage(targetPage)
                }
                debugPlaybackPagingStatus = "go \(targetPage) by offset now \(scrollState.currentPage)"
                return
            }
            guard let rect = playbackHighlightContentRect(highlight, viewport: layoutViewport) else {
                debugPlaybackPagingStatus = "no-rect item \(highlight.itemIndex)"
                return
            }
            guard let targetPage = scrollState.forwardPlaybackTargetPage(
                for: rect,
                viewportHeight: Double(paginationViewportHeight),
                isWordHighlight: highlight.wordRange != nil
            ) else {
                debugPlaybackPagingStatus = "no-target y \(Int(rect.minY)) p \(scrollState.pageContaining(y: Double(rect.minY) + 0.5))"
                return
            }
            debugPlaybackPagingStatus = "go \(targetPage) y \(Int(rect.minY))"
            withAnimation(pageAnimation) {
                scrollState.goToPage(targetPage)
            }
            debugPlaybackPagingStatus = "go \(targetPage) y \(Int(rect.minY)) now \(scrollState.currentPage)"
        }
        .onDisappear {
            speechCoordinator.stop()
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

    private func activateOrCommitHighlight(
        viewportWidth: CGFloat,
        viewportHeight: CGFloat
    ) {
        if autoHighlightSelection != nil {
            confirmPendingHighlight()
            return
        }

        selectNextHighlight(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight
        )
    }

    private func selectNextHighlight(
        viewportWidth: CGFloat,
        viewportHeight: CGFloat
    ) {
        handleAutoHighlightUpdate(cycleHighlightForTopVisibleParagraph(
            viewportWidth: viewportWidth,
            scrollViewHeight: viewportHeight,
            topFadeHeight: 0,
            scrollOffset: scrollState.offset
        ))
    }

    private func selectPreviousHighlight(
        viewportWidth: CGFloat,
        viewportHeight: CGFloat
    ) {
        handleAutoHighlightUpdate(previousHighlightForTopVisibleParagraph(
            viewportWidth: viewportWidth,
            scrollViewHeight: viewportHeight,
            topFadeHeight: 0,
            scrollOffset: scrollState.offset
        ))
    }

    private func reservedBottomLineHeight() -> CGFloat {
        let sample = nsStyledText("Ag", size: readerSettings.paragraphSize, weight: .regular)
        if let line = Paginator.measureLines(for: sample, width: 1000).first {
            return CGFloat(line.maxY - line.minY)
        }
        return readerSettings.paragraphSize * 1.2
            + readerSettings.lineSpacingPt(for: readerSettings.paragraphSize)
    }

    private func contentFrames(from scrollFrames: [Int: CGRect]) -> [Int: CGRect] {
        let offset = CGFloat(scrollState.offset)
        return scrollFrames.mapValues { frame in
            CGRect(
                x: frame.minX,
                y: frame.minY - offset,
                width: frame.width,
                height: frame.height
            )
        }
    }

    private func updateVisibleParagraphs(
        positions: [Int: CGRect],
        viewportWidth: CGFloat,
        viewportHeight: CGFloat
    ) {
        let viewport = CGRect(
            x: 0,
            y: -CGFloat(scrollState.offset),
            width: viewportWidth,
            height: viewportHeight
        )
        let newVisible = positions
            .filter { $0.value.intersects(viewport) }
            .map { $0.key }
            .sorted()
        if newVisible != visibleParagraphs {
            visibleParagraphs = newVisible
        }
    }

    private func handleAutoHighlightUpdate(_ update: AutoHighlightUpdate) {
        guard case .changed(let targetOffset) = update,
              let offset = targetOffset else {
            return
        }

        hideTopBarIfNeeded()
        withAnimation(pageAnimation) {
            scrollState.goToContentOffset(offset)
        }
    }

    func startPlayback(at location: PlaybackTextLocation) {
        speechCoordinator.start(segments: playbackSegments(startingAt: location))
    }
}
