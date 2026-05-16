import SwiftUI
import UIKit
import CoreHaptics
import NaturalLanguage
@preconcurrency import OpenAI
import QuartzCore
import SafariServices

// External callbacks for non-reader hosts (e.g. onboarding) that need to drive
// their own UI off the real reader's interactions without copying its internals.
struct ScrollTextViewObserver {
    var onTrackpadSwipe: ((_ isHighlightMode: Bool) -> Void)? = nil
    var onHighlightModeChanged: ((_ isHighlightMode: Bool) -> Void)? = nil
    var onHighlightCommit: (() -> Void)? = nil
    var onExplainerDismissed: (() -> Void)? = nil
}

struct ScrollTextView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(HighlightStore.self) var highlightStore

    @StateObject var scrollState = ScrollState()
    @EnvironmentObject var readerSettings: ReaderSettings
    @StateObject var speechCoordinator = ReaderSpeechCoordinator()
    @State var isSettingsMode: Bool = false
    @State var visibleParagraphs: [Int] = []
    @State var spinCount: Int = 0
    @State var lastAnalyzedText: String = ""
    @State var lastTaggedText: String = ""
    @State var tags: [String] = []
    @State var chapterTags: [String] = []
    @State var currentQuestion: String = ""
    @State var isLoadingQuestion: Bool = false
    @State private var explainerURL: IdentifiableURL?
    @State var analysisTask: Task<Void, Never>?
    @State private var showReaderSettings: Bool = false
    @State private var showHighlightsList: Bool = false
    @State private var showPlaybackSpeedOverlay: Bool = false
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
    let bookTitle: String
    let bookAuthor: String
    let bookDescription: String
    let observer: ScrollTextViewObserver
    // Must stay same length/order as `items`. Each entry scopes persisted highlights to one rendered item.
    @State var itemContentIDs: [String] = []
    // Editorial whitespace between the status bar/safe area and the first line of body text.
    private let editorialTopPadding: CGFloat = 6
    private let viewportTopOffset: CGFloat = 15
    // Gap between the text viewport's bottom and the top of the control panel so no text sits
    // behind the liquid-glass material.
    private let viewportToPanelGap: CGFloat = 8
    private let panelTopGap: CGFloat = 4
    private let panelBottomInset: CGFloat = 24
    let maxTags = 5
    private let pageAnimation: Animation = .spring(response: 0.3, dampingFraction: 0.88)

    init(
        chapters: [EpubChapter],
        startingIndex: Int,
        bookID: String = "",
        bookTitle: String = "",
        bookAuthor: String = "",
        bookDescription: String = "",
        observer: ScrollTextViewObserver = ScrollTextViewObserver()
    ) {
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
        self.bookTitle = bookTitle
        self.bookAuthor = bookAuthor
        self.bookDescription = bookDescription
        self.observer = observer
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
            let isPlaybackMode = speechCoordinator.isPlaybackActive || speechCoordinator.isPreparingPlayback
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

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleSettingsMode()
                }

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
            .contentShape(Rectangle())
            .coordinateSpace(name: "scroll")
            .frame(width: viewportWidth, height: visiblePageHeight, alignment: .top)
            .clipped()
            .position(x: viewportWidth / 2, y: viewportTop + visiblePageHeight / 2)
            .opacity(isSettingsMode ? 0.42 : 1)
            .scrollDisabled(true)
            .onTapGesture {
                toggleSettingsMode()
            }
            .animation(.easeInOut(duration: 0.2), value: isSettingsMode)
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
            .onChange(of: readerSettings.readerHeaderFont) { _, _ in
                recomputePageStartsWithCurrentFrames(
                    viewportHeight: Double(viewportHeight),
                    viewportWidth: Double(viewportWidth)
                )
            }
            .onChange(of: readerSettings.readerBodyFont) { _, _ in
                recomputePageStartsWithCurrentFrames(
                    viewportHeight: Double(viewportHeight),
                    viewportWidth: Double(viewportWidth)
                )
            }
            .onChange(of: readerSettings.highlightColors) { _, newValue in
                if !newValue.contains(selectedHighlightColor) {
                    selectedHighlightColor = newValue.first ?? .yellow
                }
            }
            .onChange(of: readerSettings.highlightEmojis) { _, newValue in
                if let active = selectedHighlightEmoji, !newValue.contains(active) {
                    selectedHighlightEmoji = nil
                }
            }
            // The text viewport is locked to the normal panel height so entering highlight mode
            // never shifts the page. Only normal-mode panel measurement can change pagination.
            .onChange(of: frozenPanelHeight) { _, _ in
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
                isPlaybackMode: isPlaybackMode,
                availableHighlightColors: readerSettings.highlightColors,
                availableHighlightEmojis: readerSettings.highlightEmojis,
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
                onTrackpadSwipeDown: {
                    handleTrackpadSwipe(
                        isSwipeUp: false,
                        viewportWidth: geometry.size.width,
                        viewportHeight: highlightSelectionViewportHeight,
                        isHighlightMode: isHighlightMode
                    )
                },
                onTrackpadSwipeUp: {
                    handleTrackpadSwipe(
                        isSwipeUp: true,
                        viewportWidth: geometry.size.width,
                        viewportHeight: highlightSelectionViewportHeight,
                        isHighlightMode: isHighlightMode
                    )
                },
                isPlaybackSpeaking: speechCoordinator.isSpeaking,
                isPlaybackPaused: speechCoordinator.isPaused,
                isPlaybackPreparing: speechCoordinator.isPreparingPlayback,
                playbackSpeed: speechCoordinator.playbackSpeed,
                playbackLevel: speechCoordinator.playbackLevel,
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
                        ),
                        title: chapters[chapterIndex].title
                    )
                },
                onPlaybackSpeedTap: {
                    showPlaybackSpeedOverlay = true
                },
                onPlaybackSkipBackward: {
                    speechCoordinator.skipBackward15Seconds()
                },
                onPlaybackSkipForward: {
                    speechCoordinator.skipForward15Seconds()
                },
                onPlaybackStop: {
                    speechCoordinator.stop(clearHighlight: true)
                    showPlaybackSpeedOverlay = false
                },
                tags: readerSettings.showAIQuestions ? Array(tags.prefix(maxTags)) : [],
                actions: readerSettings.showAIQuestions ? readerSettings.panelActions : [],
                onActionTap: { action in
                    openPerplexity(for: action)
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
                    // Normal-mode panel height drives pagination. Highlight- and playback-mode
                    // panel growth intentionally overlays the page without changing the text viewport.
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
                let isExpandedMode = autoHighlightSelection != nil
                    || speechCoordinator.isPlaybackActive
                    || speechCoordinator.isPreparingPlayback
                if !isExpandedMode && abs(value - frozenPanelHeight) > 0.5 {
                    frozenPanelHeight = value
                }
            }

            if showsBackButton {
                settingsModeNavigationRow
                    .padding(.horizontal, 34)
                    .padding(.bottom, max(activePanelHeight, frozenPanelHeight) + panelBottomInset + 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .opacity(isSettingsMode ? 1 : 0)
                    .scaleEffect(isSettingsMode ? 1 : 0.96)
                    .allowsHitTesting(isSettingsMode)
                    .animation(.spring(response: 0.24, dampingFraction: 0.9), value: isSettingsMode)
                    .zIndex(4)
            }

            if showPlaybackSpeedOverlay {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture {
                        showPlaybackSpeedOverlay = false
                    }

                PlaybackSpeedOverlay(
                    speed: speechCoordinator.playbackSpeed,
                    onSpeedChanged: { speed in
                        speechCoordinator.setPlaybackSpeed(speed)
                    },
                    onSave: {
                        showPlaybackSpeedOverlay = false
                    }
                )
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(10)
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
        .statusBar(hidden: true)
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
        .sheet(item: $explainerURL, onDismiss: {
            observer.onExplainerDismissed?()
        }) { item in
            SafariView(url: item.url)
        }
        .onChange(of: autoHighlightSelection != nil) { _, newValue in
            observer.onHighlightModeChanged?(newValue)
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
        .onAppear {
            seedChapterTags()
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
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: showPlaybackSpeedOverlay)
    }

    func presentExplainer(for query: String) {
        guard let url = perplexityURL(for: query) else { return }
        explainerURL = IdentifiableURL(url: url)
    }

    private var settingsModeNavigationRow: some View {
        HStack(spacing: 12) {
            FloatingSettingsButton(
                systemImage: "house.fill",
                accessibilityLabel: "Home"
            ) {
                dismiss()
            }

            Spacer(minLength: 0)

            FloatingSettingsButton(
                systemImage: "highlighter",
                accessibilityLabel: "Highlights"
            ) {
                showHighlightsList = true
            }

            FloatingSettingsButton(
                systemImage: "textformat.size",
                accessibilityLabel: "Text settings"
            ) {
                showReaderSettings = true
            }
        }
    }

    func toggleSettingsMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isSettingsMode.toggle()
        }
    }

    private func hideSettingsModeIfNeeded() {
        guard isSettingsMode else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            isSettingsMode = false
        }
    }

    private func handleTrackpadSwipe(
        isSwipeUp: Bool,
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        isHighlightMode: Bool
    ) {
        observer.onTrackpadSwipe?(isHighlightMode)
        if isHighlightMode {
            let extendDown = isSwipeUp == readerSettings.invertHighlightSwipe
            if extendDown {
                selectNextHighlight(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
            } else {
                selectPreviousHighlight(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
            }
            return
        }
        let goNext = isSwipeUp != readerSettings.invertTrackpadSwipe
        if goNext {
            goToNextPageWithFeedback()
        } else {
            goToPreviousPageWithFeedback()
        }
    }

    func goToPreviousPageWithFeedback() {
        hideSettingsModeIfNeeded()
        withAnimation(pageAnimation) {
            scrollState.goToPreviousPage()
        }
    }

    func goToNextPageWithFeedback() {
        hideSettingsModeIfNeeded()
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
    }

    private func activateOrCommitHighlight(
        viewportWidth: CGFloat,
        viewportHeight: CGFloat
    ) {
        if autoHighlightSelection != nil {
            confirmPendingHighlight()
            observer.onHighlightCommit?()
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
            updateTagsForVisibleParagraphs(newVisible)
        }
    }

    private func handleAutoHighlightUpdate(_ update: AutoHighlightUpdate) {
        guard case .changed(let targetPage) = update,
              let page = targetPage else {
            return
        }

        hideSettingsModeIfNeeded()
        withAnimation(pageAnimation) {
            scrollState.goToPage(page)
        }
    }

    func startPlayback(at location: PlaybackTextLocation) {
        speechCoordinator.start(
            segments: playbackSegments(startingAt: location),
            title: chapters[chapterIndex].title
        )
    }
}

private struct FloatingSettingsButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 46, height: 46)
                .liquidGlass(in: Circle(), tint: Color.black.opacity(0.58))
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct PlaybackSpeedOverlay: View {
    let speed: Double
    let onSpeedChanged: (Double) -> Void
    let onSave: () -> Void
    @State private var dragOffset: CGFloat = 0

    private let presetSpeeds = PlaybackSpeedPreference.presets

    var body: some View {
        VStack(spacing: 24) {
            Capsule()
                .fill(Color.white.opacity(0.24))
                .frame(width: 42, height: 5)
                .padding(.top, 10)

            VStack(spacing: 6) {
                Text("Audio Narration")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white.opacity(0.45))

                Text("Reading Speed")
                    .dmSansBold(size: 24)
                    .foregroundColor(.white.opacity(0.95))

                Text(PlaybackSpeedPreference.label(for: speed))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.62))
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 12) {
                Slider(
                    value: Binding(
                        get: { speed },
                        set: { onSpeedChanged(PlaybackSpeedPreference.clamped($0)) }
                    ),
                    in: 0.5...4.0,
                    step: 0.05
                )
                .tint(.white)

                HStack {
                    ForEach([0.5, 1.0, 2.0, 3.0, 4.0], id: \.self) { tick in
                        Text(PlaybackSpeedPreference.label(for: tick))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.38))
                        if tick != 4.0 {
                            Spacer()
                        }
                    }
                }
            }
            .padding(.horizontal, 2)

            HStack(spacing: 8) {
                ForEach(presetSpeeds, id: \.self) { preset in
                    let isSelected = abs(speed - preset) < 0.025
                    Button {
                        onSpeedChanged(preset)
                    } label: {
                        Text(PlaybackSpeedPreference.label(for: preset))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(isSelected ? .black : .white.opacity(0.82))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(isSelected ? Color.white : Color.white.opacity(0.08))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Set speed to \(PlaybackSpeedPreference.label(for: preset))")
                }
            }

            Button(action: onSave) {
                Text("Done")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 12)
        .offset(y: max(0, dragOffset))
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    dragOffset = max(0, value.translation.height)
                }
                .onEnded { value in
                    let shouldDismiss = value.translation.height > 80 || value.predictedEndTranslation.height > 160
                    if shouldDismiss {
                        onSave()
                    } else {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            dragOffset = 0
                        }
                    }
                }
        )
    }
}
