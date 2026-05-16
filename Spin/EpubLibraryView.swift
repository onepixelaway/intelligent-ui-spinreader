import SwiftUI
import UIKit
import SceneKit
import UniformTypeIdentifiers
import WebKit
import ImageIO

struct EpubLibraryView: View {
    @StateObject private var library = EpubLibrary()
    @StateObject private var articleStore = WebArticleStore()
    @StateObject private var backgroundImporter = BackgroundArticleImporter()
    @EnvironmentObject private var shareInbox: ShareImportInbox
    @State private var showImporter = false
    @State private var showBrowser = false
    @State private var showPasteText = false
    @State private var errorMessage: String?
    @State private var shareImportDiagnostic: ShareImportDiagnostic?
    @State private var isImportingArticle = false
    @State private var isHandlingSharedArticleImport = false
    @State private var isJiggling = false
    @State private var bookPendingDeletion: EpubBook?
    @State private var navigationPath = NavigationPath()

    private static func articleBookID(_ article: WebArticle) -> String {
        "article:\(article.id.uuidString)"
    }

    private static let sampleArticleURL = URL(string: "https://sfalexandria.com/posts/farzas-creations/")!

    /// Any books or saved articles (placeholders alone do not count).
    private var hasLibraryContent: Bool {
        !library.books.isEmpty || !articleStore.articles.isEmpty
    }

    private var bookCarouselPlaceholderCount: Int {
        max(0, 3 - library.books.count)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                LibraryTheme.appBackground.ignoresSafeArea()

                if library.isLoading && !hasLibraryContent {
                    ProgressView()
                        .tint(.white.opacity(0.6))
                } else {
                    libraryScrollContent
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: EpubBook.self) { book in
                ChapterListView(book: book)
            }
            .navigationDestination(for: WebArticle.self) { article in
                ScrollTextView(
                    chapters: [article.asChapter()],
                    startingIndex: 0,
                    bookID: Self.articleBookID(article)
                )
                .toolbar(.hidden, for: .navigationBar)
                .navigationBarBackButtonHidden(true)
            }
            .darkNavigationBar()
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.epub],
                allowsMultipleSelection: true
            ) { result in
                Task { await handleImport(result: result) }
            }
            .sheet(isPresented: $showBrowser) {
                BrowserView(initialURL: nil) { webView, url in
                    showBrowser = false
                    Task { await handleArticleImport(webView: webView, url: url) }
                }
            }
            .sheet(isPresented: $showPasteText) {
                PasteTextView(
                    onSave: { title, body in
                        showPasteText = false
                        Task { await handlePastedText(title: title, body: body) }
                    },
                    onCancel: { showPasteText = false }
                )
            }
            .overlay {
                if isImportingArticle {
                    ZStack {
                        Color.black.opacity(0.55).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView().tint(.white)
                            Text("Saving article…")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.85))
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 22)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color(white: 0.12))
                        )
                    }
                    .transition(.opacity)
                }
            }
            .safeAreaInset(edge: .bottom) {
                ImportToast(phase: backgroundImporter.phase)
                    .animation(.easeInOut(duration: 0.25), value: backgroundImporter.phase)
            }
            .alert(
                "Couldn't import",
                isPresented: errorBinding,
                actions: {
                    Button("OK", role: .cancel) {}
                },
                message: {
                    Text(errorMessage ?? "")
                }
            )
            .alert(
                "Couldn't import article",
                isPresented: shareImportDiagnosticBinding,
                actions: {
                    Button("Copy diagnostic report") {
                        if let shareImportDiagnostic {
                            UIPasteboard.general.string = shareImportDiagnostic.clipboardReport
                        }
                    }
                    Button("OK", role: .cancel) {
                        shareImportDiagnostic = nil
                    }
                },
                message: {
                    Text(shareImportDiagnostic?.userVisibleSummary ?? "")
                }
            )
            .alert(
                bookPendingDeletion.map { "Delete \"\($0.title)\"?" } ?? "Delete book?",
                isPresented: deleteAlertBinding,
                presenting: bookPendingDeletion
            ) { book in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    library.delete(book)
                    if !hasLibraryContent {
                        withAnimation(.easeOut(duration: 0.2)) { isJiggling = false }
                    }
                }
            } message: { _ in
                Text("This cannot be undone.")
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await library.seedDefaultEpubs()
            if library.books.isEmpty {
                await library.loadFromDisk()
            }
            if articleStore.articles.isEmpty {
                await articleStore.loadFromDisk()
            }
            await seedSampleArticleIfNeeded()
        }
        .onChange(of: shareInbox.pendingURL, initial: true) { _, url in
            guard let url else { return }
            shareInbox.clear()
            isHandlingSharedArticleImport = true
            Task { @MainActor in
                await backgroundImporter.importArticle(from: url, into: articleStore)
                isHandlingSharedArticleImport = false
            }
        }
        .onChange(of: backgroundImporter.phase) { _, phase in
            if case .failure(let diagnostic) = phase {
                shareImportDiagnostic = diagnostic
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var shareImportDiagnosticBinding: Binding<Bool> {
        Binding(
            get: { shareImportDiagnostic != nil },
            set: { if !$0 { shareImportDiagnostic = nil } }
        )
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { bookPendingDeletion != nil },
            set: { if !$0 { bookPendingDeletion = nil } }
        )
    }

    private var libraryHeader: some View {
        HStack(alignment: .center) {
            Text("Ponder")
                .font(LibraryTheme.appTitleFont)
                .foregroundColor(.white)
            Spacer(minLength: 12)
            if isJiggling {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { isJiggling = false }
                } label: {
                    Text("Done")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(height: LibraryLayout.iconButtonSize)
                        .padding(.horizontal, 18)
                        .background(
                            Capsule()
                                .stroke(LibraryTheme.iconButtonBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 12) {
                    Button {} label: {
                        LibraryIconButtonImage(systemName: "magnifyingglass")
                    }
                    .buttonStyle(LibraryIconButtonStyle())
                    .accessibilityLabel("Search")

                    NavigationLink {
                        SettingsView(articleStore: articleStore)
                    } label: {
                        LibraryIconButtonImage(systemName: "gearshape")
                    }
                    .buttonStyle(LibraryIconButtonStyle())
                    .accessibilityLabel("Settings")
                }
            }
        }
        .padding(.horizontal, LibraryLayout.gutter)
    }

    private var libraryScrollContent: some View {
        GeometryReader { proxy in
            let screenWidth = proxy.size.width
            let heroHeight = proxy.size.height * LibraryLayout.floatingSkyHeightRatio
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    floatingBooksHero(height: heroHeight)

                    VStack(alignment: .leading, spacing: 32) {
                        addNewSection
                        booksCarouselSection(screenWidth: screenWidth)
                        articlesStackSection
                    }
                    .padding(.top, 22)
                    .padding(.bottom, 32)
                    .frame(width: screenWidth, alignment: .leading)
                }
                .frame(width: screenWidth, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(name: LibraryLayout.scrollCoordinateSpaceName)
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isJiggling {
                            withAnimation(.easeOut(duration: 0.2)) { isJiggling = false }
                        }
                    }
            )
        }
    }

    private var addNewSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            libraryHeader
                .padding(.bottom, 2)

            sectionHeader("Add new")

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                alignment: .center,
                spacing: 10
            ) {
                ActionTile(title: "Write\ntext", systemImage: "textformat") {
                    showPasteText = true
                }
                ActionTile(title: "Upload\na file", systemImage: "book") {
                    showImporter = true
                }
                ActionTile(title: "Paste\na link", systemImage: "globe") {
                    showBrowser = true
                }
            }
            .padding(.horizontal, LibraryLayout.gutter)
        }
    }

    private func booksCarouselSection(screenWidth: CGFloat) -> some View {
        let cardWidth = max(280, screenWidth * LibraryLayout.bookCarouselWidthRatio)

        return VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Books")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(library.books.enumerated()), id: \.element.id) { index, book in
                        bookCarouselCell(book: book, index: index, cardWidth: cardWidth)
                    }
                    ForEach(0..<bookCarouselPlaceholderCount, id: \.self) { slot in
                        BookCarouselPlaceholder()
                            .frame(width: cardWidth, height: LibraryLayout.bookCardHeight)
                            .id("placeholder-\(slot)")
                    }
                }
                .scrollTargetLayout()
                .padding(.leading, LibraryLayout.bookScrollerLeading)
                .padding(.trailing, LibraryLayout.gutter)
            }
            .scrollTargetBehavior(.viewAligned)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var articlesStackSection: some View {
        if !articleStore.articles.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("Articles")
                LazyVStack(spacing: 24) {
                    ForEach(Array(articleStore.articles.enumerated()), id: \.element.id) { index, article in
                        articleRowCell(article: article, index: index)
                    }
                }
                .padding(.horizontal, LibraryLayout.gutter)
            }
        }
    }

    private func floatingBooksHero(height: CGFloat) -> some View {
        GeometryReader { geo in
            let minY = geo.frame(in: .named(LibraryLayout.scrollCoordinateSpaceName)).minY
            let pullDown = max(0, minY)
            let scrollUp = min(0, minY)

            ZStack(alignment: .top) {
                FloatingBooksStarfield(scrollOffset: minY)
                    .scaleEffect(1 + min(pullDown / 900, 0.08), anchor: .top)

                FloatingBooksSkySceneView(scrollOffset: minY)
                    .frame(height: geo.size.height + pullDown * 0.35)
                    .offset(y: (-scrollUp * 0.38) - (pullDown * 0.08))

                LinearGradient(
                    colors: [
                        LibraryTheme.appBackground,
                        LibraryTheme.appBackground.opacity(0.72),
                        LibraryTheme.appBackground.opacity(0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 132)
                .allowsHitTesting(false)

                VStack {
                    Spacer()
                    LinearGradient(
                        colors: [
                            LibraryTheme.appBackground.opacity(0),
                            LibraryTheme.appBackground.opacity(0.58),
                            LibraryTheme.appBackground
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 180)
                }
                .allowsHitTesting(false)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .frame(height: height)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(LibraryTheme.sectionHeadingFont)
            .foregroundColor(.white)
            .padding(.horizontal, LibraryLayout.gutter)
    }

    @ViewBuilder
    private func bookCarouselCell(book: EpubBook, index: Int, cardWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            BookCarouselCard(book: book)
                .frame(width: cardWidth, height: LibraryLayout.bookCardHeight)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isJiggling {
                        navigationPath.append(book)
                    }
                }
                .onLongPressGesture(minimumDuration: 0.5) {
                    if !isJiggling {
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.impactOccurred()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            isJiggling = true
                        }
                    }
                }

            if isJiggling {
                deleteButton(for: book)
                    .offset(x: -8, y: -8)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .modifier(JiggleModifier(isJiggling: isJiggling, index: index))
    }

    @ViewBuilder
    private func articleRowCell(article: WebArticle, index: Int) -> some View {
        ZStack(alignment: .topLeading) {
            ArticlePreviewCard(article: article)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isJiggling {
                        navigationPath.append(article)
                    }
                }
                .onLongPressGesture(minimumDuration: 0.5) {
                    if !isJiggling {
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.impactOccurred()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            isJiggling = true
                        }
                    }
                }

            if isJiggling {
                deleteButton(for: article)
                    .offset(x: -8, y: -8)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .modifier(JiggleModifier(isJiggling: isJiggling, index: index))
    }

    private func deleteButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.black))
                .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func deleteButton(for book: EpubBook) -> some View {
        deleteButton { bookPendingDeletion = book }
    }

    private func deleteButton(for article: WebArticle) -> some View {
        deleteButton {
            articleStore.delete(article)
            if !hasLibraryContent {
                withAnimation(.easeOut(duration: 0.2)) { isJiggling = false }
            }
        }
    }

    private func handleImport(result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            for url in urls {
                do {
                    _ = try await library.importFile(at: url)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func handlePastedText(title: String, body: String) async {
        let resolvedTitle = MarkdownParser.resolveTitle(userInput: title, from: body)
        let items = MarkdownParser.parse(text: body)
        guard !items.isEmpty else { return }
        let article = WebArticle(
            id: UUID(),
            title: resolvedTitle,
            author: "",
            sourceURL: nil,
            savedAt: Date(),
            items: items
        )
        do {
            try await articleStore.save(article)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleArticleImport(webView: WKWebView, url: URL) async {
        isImportingArticle = true
        defer { isImportingArticle = false }
        do {
            let article = try await extractArticle(from: webView, sourceURL: url)
            try await articleStore.save(article)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func seedSampleArticleIfNeeded() async {
        guard shareInbox.pendingURL == nil else { return }
        guard !isHandlingSharedArticleImport else { return }
        guard !articleStore.containsArticle(sourceURL: Self.sampleArticleURL) else { return }
        await backgroundImporter.importArticle(from: Self.sampleArticleURL, into: articleStore)
    }
}

private struct JiggleModifier: ViewModifier {
    let isJiggling: Bool
    let index: Int
    @State private var rotation: Double = 0

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(rotation))
            .onChange(of: isJiggling, initial: true) { _, newValue in
                if newValue {
                    var snap = Transaction()
                    snap.disablesAnimations = true
                    withTransaction(snap) { rotation = -2 }
                    withAnimation(
                        .easeInOut(duration: 0.13)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index % 7) * 0.02)
                    ) {
                        rotation = 2
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.15)) {
                        rotation = 0
                    }
                }
            }
    }
}

private enum LibraryLayout {
    static let gutter: CGFloat = 24
    static let bookScrollerLeading: CGFloat = 12
    static let bookCarouselWidthRatio: CGFloat = 0.78
    static let floatingSkyHeightRatio: CGFloat = 0.67
    static let scrollCoordinateSpaceName = "library-scroll"
    static let bookCardHeight: CGFloat = 120
    static let bookCoverWidth: CGFloat = 88
    static let actionTileHeight: CGFloat = 84
    static let iconButtonSize: CGFloat = 44
    static let articleHeroHeight: CGFloat = 160
    static let cornerRadius: CGFloat = 16
}

private enum LibraryTheme {
    static let appBackground = Color(hex: 0x0A0A0A)
    static let cardSurface = Color(hex: 0x18181B).opacity(0.4)
    static let tileSurface = Color(hex: 0x27272A).opacity(0.6)
    static let iconButtonBorder = Color(hex: 0x3F3F46).opacity(0.8)
    static let textSecondary = Color(hex: 0xA1A1AA)
    static let accentByline = Color(hex: 0xFDE68A).opacity(0.8)
    static let articleSurface = Color(hex: 0x2A241C)

    static let appTitleFont = Font.system(size: 34, weight: .bold)
    static let sectionHeadingFont = Font.system(size: 22, weight: .bold)
    static let cardTitleFont = Font.system(size: 17, weight: .semibold)
    static let articleTitleFont = Font.system(size: 18, weight: .semibold)
    static let captionFont = Font.system(size: 13, weight: .medium)
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

private struct LibraryIconButtonImage: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 20, weight: .regular))
            .symbolRenderingMode(.monochrome)
            .foregroundColor(.white.opacity(0.92))
            .frame(width: LibraryLayout.iconButtonSize, height: LibraryLayout.iconButtonSize)
    }
}

private struct LibraryIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle()
                    .fill(configuration.isPressed ? Color.white.opacity(0.06) : Color.clear)
            )
            .overlay(
                Circle()
                    .stroke(LibraryTheme.iconButtonBorder, lineWidth: 1)
            )
    }
}

private struct PressableScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: configuration.isPressed)
    }
}

private struct ActionTile: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .regular))
                    .symbolRenderingMode(.monochrome)
                    .foregroundColor(.white)
                    .frame(height: 34)

                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.86)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .frame(height: LibraryLayout.actionTileHeight)
            .background(
                RoundedRectangle(cornerRadius: LibraryLayout.cornerRadius, style: .continuous)
                    .fill(LibraryTheme.tileSurface)
            )
            .contentShape(RoundedRectangle(cornerRadius: LibraryLayout.cornerRadius, style: .continuous))
        }
        .buttonStyle(PressableScaleButtonStyle())
    }
}

private struct BookCarouselCard: View {
    let book: EpubBook

    var body: some View {
        HStack(spacing: 12) {
            coverImage
                .frame(width: LibraryLayout.bookCoverWidth, height: LibraryLayout.bookCardHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 0) {
                Text(book.title)
                    .font(LibraryTheme.cardTitleFont)
                    .foregroundColor(.white)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 8)

                Text(book.author.isEmpty ? "Unknown Author" : book.author)
                    .font(LibraryTheme.captionFont)
                    .foregroundColor(LibraryTheme.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: LibraryLayout.cornerRadius, style: .continuous)
                .fill(LibraryTheme.cardSurface)
        )
        .contentShape(RoundedRectangle(cornerRadius: LibraryLayout.cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var coverImage: some View {
        if let data = book.coverImageData, let uiImage = UIImage(data: data) {
            Color.clear
                .overlay {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
        } else {
            PlaceholderCover(title: book.title, author: book.author)
        }
    }
}

private struct BookCarouselPlaceholder: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 0.16))
                .frame(width: LibraryLayout.bookCoverWidth, height: LibraryLayout.bookCardHeight)

            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.16))
                    .frame(width: 160, height: 16)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 118, height: 16)
                Spacer()
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 92, height: 12)
            }
            .padding(.vertical, 16)
        }
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: LibraryLayout.cornerRadius, style: .continuous)
                .fill(LibraryTheme.cardSurface)
        )
    }
}

private struct ArticlePreviewCard: View {
    let article: WebArticle
    @State private var localCover: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroImage
                .frame(maxWidth: .infinity)
                .frame(height: LibraryLayout.articleHeroHeight)
                .clipped()

            VStack(alignment: .leading, spacing: 6) {
                Text(article.bylineDisplay)
                    .font(LibraryTheme.captionFont)
                    .foregroundColor(LibraryTheme.accentByline)
                    .lineLimit(1)

                Text(article.title)
                    .font(LibraryTheme.articleTitleFont)
                    .foregroundColor(.white)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LibraryTheme.articleSurface)
        .clipShape(RoundedRectangle(cornerRadius: LibraryLayout.cornerRadius, style: .continuous))
        .task(id: article.id) {
            await loadLocalCover()
        }
    }

    @ViewBuilder
    private var heroImage: some View {
        if let localCover {
            Image(uiImage: localCover)
                .resizable()
                .scaledToFill()
        } else if let remote = article.firstRemotePreviewImageURL {
            AsyncImage(url: remote) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    heroPlaceholder
                case .empty:
                    heroPlaceholder.overlay {
                        ProgressView().tint(.white.opacity(0.55))
                    }
                @unknown default:
                    heroPlaceholder
                }
            }
        } else {
            heroPlaceholder
        }
    }

    private var heroPlaceholder: some View {
        let colors = deterministicGradient(for: article.title + (article.sourceURL?.host ?? ""))
        return ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: article.sourceURL == nil ? "doc.on.clipboard" : "globe")
                .font(.system(size: 36, weight: .light))
                .foregroundColor(.white.opacity(0.78))
        }
    }

    private func loadLocalCover() async {
        guard let url = article.coverImageURL else {
            localCover = nil
            return
        }
        let image: UIImage? = await Task.detached(priority: .userInitiated) {
            downsampledImage(at: url, maxPixelSize: 900)
        }.value
        localCover = image
    }
}

private extension WebArticle {
    var bylineDisplay: String {
        let trimmedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAuthor.isEmpty {
            return trimmedAuthor
        }
        if let host = sourceURL?.displayHost, !host.isEmpty {
            return host
        }
        return "Ponder"
    }
}

private func downsampledImage(at url: URL, maxPixelSize: Int) -> UIImage? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
    let options = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
    ] as CFDictionary
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
    return UIImage(cgImage: cgImage)
}

private struct PlaceholderCover: View {
    let title: String
    let author: String

    var body: some View {
        GeometryReader { geo in
            let colors = deterministicGradient(for: title)
            ZStack {
                LinearGradient(
                    colors: colors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                VStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: min(geo.size.width * 0.1, 15), weight: .semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding(.horizontal, 12)
                    if !author.isEmpty {
                        Text(author)
                            .font(.system(size: min(geo.size.width * 0.07, 11)))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                    }
                }
            }
        }
    }
}

private func deterministicGradient(for seed: String) -> [Color] {
    var hash: UInt64 = 5381
    for byte in seed.utf8 {
        hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
    }
    let hue1 = Double(hash % 360) / 360.0
    let hue2 = Double((hash / 360) % 360) / 360.0
    return [
        Color(hue: hue1, saturation: 0.55, brightness: 0.38),
        Color(hue: hue2, saturation: 0.62, brightness: 0.24)
    ]
}

private struct FloatingBooksStarfield: View {
    let scrollOffset: CGFloat

    private static let stars = (0..<82).map { FloatingStar(index: $0) }
    private static let dust = (0..<96).map { FloatingStar(index: $0 + 700) }

    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(LibraryTheme.appBackground)
            )

            for star in Self.dust {
                let x = star.x * size.width
                let diagonal = (star.x * 0.54 + 0.18) * size.height
                let y = diagonal + (star.y - 0.5) * size.height * 0.28 + (-scrollOffset * star.parallax)
                guard y > -8, y < size.height + 8 else { continue }

                let rect = CGRect(
                    x: x,
                    y: y,
                    width: star.radius,
                    height: star.radius
                )
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(Color.white.opacity(star.alpha * 0.08))
                )
            }

            for star in Self.stars {
                let x = star.x * size.width
                let y = star.y * size.height + (-scrollOffset * star.parallax)
                guard y > -8, y < size.height + 8 else { continue }

                let rect = CGRect(
                    x: x,
                    y: y,
                    width: star.radius,
                    height: star.radius
                )
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(Color.white.opacity(star.alpha))
                )
            }
        }
        .background(LibraryTheme.appBackground)
    }
}

private struct FloatingStar: Identifiable, Sendable {
    let id: Int
    let x: CGFloat
    let y: CGFloat
    let radius: CGFloat
    let alpha: Double
    let parallax: CGFloat

    init(index: Int) {
        id = index
        var state = UInt64(index + 1) &* 2_654_435_761
        x = Self.random(&state)
        y = Self.random(&state)
        radius = 0.35 + Self.random(&state) * 1.2
        alpha = Double(0.24 + Self.random(&state) * 0.48)
        parallax = 0.04 + Self.random(&state) * 0.18
    }

    private static func random(_ state: inout UInt64) -> CGFloat {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let value = Double((state >> 11) & 0x1F_FFFF) / Double(0x1F_FFFF)
        return CGFloat(value)
    }
}

private struct FloatingBooksSkySceneView: UIViewRepresentable {
    let scrollOffset: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        let sceneBundle = FloatingBooksSceneFactory.makeScene()

        context.coordinator.cameraNode = sceneBundle.cameraNode
        context.coordinator.booksRootNode = sceneBundle.booksRootNode
        context.coordinator.configureInteractiveBooks(sceneBundle.interactiveBooks, in: view)

        view.scene = sceneBundle.scene
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = true
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        view.isPlaying = true

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)

        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let progress = Float(min(max(-scrollOffset / 520, -0.25), 1.35))

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.18
        context.coordinator.cameraNode?.position = SCNVector3(
            progress * 0.24,
            -progress * 0.42,
            8.2 + progress * 0.28
        )
        context.coordinator.booksRootNode?.position = SCNVector3(0, progress * 0.32, 0)
        context.coordinator.booksRootNode?.eulerAngles.z = progress * 0.025
        SCNTransaction.commit()
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var cameraNode: SCNNode?
        var booksRootNode: SCNNode?
        private weak var sceneView: SCNView?
        private var displayLink: CADisplayLink?
        private var lastFrameTime: CFTimeInterval?
        private var statesByNodeID: [ObjectIdentifier: FloatingBookInteractionState] = [:]
        private var selectedState: FloatingBookInteractionState?

        func configureInteractiveBooks(_ books: [InteractiveFloatingBook], in view: SCNView) {
            sceneView = view
            statesByNodeID = Dictionary(
                uniqueKeysWithValues: books.map {
                    (ObjectIdentifier($0.node), FloatingBookInteractionState(node: $0.node, visualScale: $0.visualScale))
                }
            )
            startDisplayLink()
        }

        func invalidate() {
            displayLink?.invalidate()
            displayLink = nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let view = sceneView else { return false }
            return interactiveRoot(at: gestureRecognizer.location(in: view)) != nil
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = sceneView else { return }

            switch recognizer.state {
            case .began:
                guard let root = interactiveRoot(at: recognizer.location(in: view)),
                      let state = statesByNodeID[ObjectIdentifier(root)] else { return }
                selectedState = state
                state.isDragging = true
                state.tiltVelocity = .zero
                state.rollVelocity = 0
                state.lastTranslation = recognizer.translation(in: view)
                state.lastTimestamp = CACurrentMediaTime()

            case .changed:
                guard let state = selectedState else { return }
                let translation = recognizer.translation(in: view)
                let now = CACurrentMediaTime()
                let elapsed = max(now - state.lastTimestamp, 1 / 120)
                let delta = CGPoint(
                    x: translation.x - state.lastTranslation.x,
                    y: translation.y - state.lastTranslation.y
                )
                let responsiveness = min(1.55, 0.78 / max(CGFloat(state.visualScale), 0.42))
                let pitchDelta = delta.y * 0.0062 * responsiveness
                let yawDelta = delta.x * 0.0072 * responsiveness
                let rollDelta = (delta.x - delta.y) * 0.0015 * responsiveness

                state.tilt.dx += pitchDelta
                state.tilt.dy += yawDelta
                state.roll += rollDelta
                state.tiltVelocity = CGVector(
                    dx: clamp(pitchDelta / elapsed, -3.4, 3.4),
                    dy: clamp(yawDelta / elapsed, -3.8, 3.8)
                )
                state.rollVelocity = clamp(rollDelta / elapsed, -2.2, 2.2)
                state.lastTranslation = translation
                state.lastTimestamp = now
                apply(state)

            case .ended, .cancelled, .failed:
                selectedState?.isDragging = false
                selectedState = nil

            default:
                break
            }
        }

        private func startDisplayLink() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(stepPhysics(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func stepPhysics(_ link: CADisplayLink) {
            let last = lastFrameTime ?? link.timestamp
            let dt = min(max(link.timestamp - last, 1 / 120), 1 / 30)
            lastFrameTime = link.timestamp

            for state in statesByNodeID.values where !state.isDragging {
                let tiltDamping = pow(0.965, dt * 60)
                state.tiltVelocity.dx *= tiltDamping
                state.tiltVelocity.dy *= tiltDamping
                state.tilt.dx += state.tiltVelocity.dx * dt
                state.tilt.dy += state.tiltVelocity.dy * dt
                state.rollVelocity *= pow(0.958, dt * 60)
                state.roll += state.rollVelocity * dt

                if hypot(state.tiltVelocity.dx, state.tiltVelocity.dy) < 0.006,
                   abs(state.rollVelocity) < 0.006 {
                    state.tiltVelocity = .zero
                    state.rollVelocity = 0
                }

                apply(state)
            }
        }

        private func apply(_ state: FloatingBookInteractionState) {
            guard let node = state.node else { return }
            node.position = SCNVector3Zero
            node.eulerAngles = SCNVector3(
                Float(state.tilt.dx),
                Float(state.tilt.dy),
                Float(state.roll)
            )
        }

        private func interactiveRoot(at location: CGPoint) -> SCNNode? {
            guard let view = sceneView else { return nil }
            let hits = view.hitTest(
                location,
                options: [
                    .boundingBoxOnly: false,
                    .ignoreHiddenNodes: true,
                    .searchMode: SCNHitTestSearchMode.closest.rawValue
                ]
            )

            for hit in hits {
                var node: SCNNode? = hit.node
                while let current = node {
                    if statesByNodeID[ObjectIdentifier(current)] != nil {
                        return current
                    }
                    node = current.parent
                }
            }
            return nil
        }

        private func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
            min(max(value, lower), upper)
        }
    }
}

private struct FloatingBooksSceneBundle {
    let scene: SCNScene
    let cameraNode: SCNNode
    let booksRootNode: SCNNode
    let interactiveBooks: [InteractiveFloatingBook]
}

private struct InteractiveFloatingBook {
    let node: SCNNode
    let visualScale: Float
}

private final class FloatingBookInteractionState {
    weak var node: SCNNode?
    let visualScale: Float
    var tilt = CGVector.zero
    var tiltVelocity = CGVector.zero
    var roll: CGFloat = 0
    var rollVelocity: CGFloat = 0
    var isDragging = false
    var lastTranslation = CGPoint.zero
    var lastTimestamp: CFTimeInterval = 0

    init(node: SCNNode, visualScale: Float) {
        self.node = node
        self.visualScale = visualScale
    }
}

private enum FloatingBooksSceneFactory {
    static func makeScene() -> FloatingBooksSceneBundle {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear

        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.fieldOfView = 46
        camera.zNear = 0.1
        camera.zFar = 100
        camera.wantsHDR = true
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 8.2)
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = UIColor(white: 0.52, alpha: 1)
        ambient.light?.intensity = 132
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.color = UIColor(red: 0.88, green: 0.92, blue: 1, alpha: 1)
        key.light?.intensity = 430
        key.light?.castsShadow = true
        key.light?.shadowRadius = 9
        key.eulerAngles = SCNVector3(-0.62, -0.72, 0.22)
        scene.rootNode.addChildNode(key)

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .omni
        rim.light?.color = UIColor(red: 0.73, green: 0.82, blue: 1, alpha: 1)
        rim.light?.intensity = 140
        rim.position = SCNVector3(-3.3, -2.0, 3.6)
        scene.rootNode.addChildNode(rim)

        let booksRoot = SCNNode()
        scene.rootNode.addChildNode(booksRoot)
        var interactiveBooks: [InteractiveFloatingBook] = []

        for spec in bookSpecs {
            let carrier = SCNNode()
            let book = makeBookNode(coverHex: spec.coverHex, seed: spec.seed)
            book.name = spec.isInteractive ? "interactive-book-\(spec.seed)" : "ambient-book-\(spec.seed)"
            if spec.isInteractive {
                book.physicsBody = SCNPhysicsBody(type: .kinematic, shape: nil)
                interactiveBooks.append(InteractiveFloatingBook(node: book, visualScale: spec.scale))
            }

            carrier.position = SCNVector3(spec.x, spec.y, spec.z)
            carrier.eulerAngles = SCNVector3(spec.pitch, spec.yaw, spec.roll)
            carrier.scale = SCNVector3(spec.scale, spec.scale, spec.scale)
            carrier.addChildNode(book)
            addMotion(to: carrier, spec: spec)
            booksRoot.addChildNode(carrier)
        }

        return FloatingBooksSceneBundle(
            scene: scene,
            cameraNode: cameraNode,
            booksRootNode: booksRoot,
            interactiveBooks: interactiveBooks
        )
    }

    private static var bookSpecs: [FloatingBookSpec] {
        let count = 11
        let loopBottomY: Float = -4.75
        let loopTopY: Float = 4.95
        let loopDistance = loopTopY - loopBottomY

        var specs: [FloatingBookSpec] = []
        specs.reserveCapacity(count)

        for index in 0..<count {
            var state = UInt64(index + 31) &* 12_989
            let isForeground = index == 0 || index == 5
            let isFar = index == 2 || index == 7
            let z: Float
            let scale: Float

            if isForeground {
                z = Float(0.58 + random(&state) * 1.45)
                scale = Float(0.5 + random(&state) * 0.24)
            } else if isFar {
                z = Float(-4.05 + random(&state) * 1.6)
                scale = Float(0.08 + random(&state) * 0.07)
            } else {
                z = Float(-2.15 + random(&state) * 2.45)
                scale = Float(0.22 + random(&state) * 0.18)
            }

            let palette: [UInt32] = [0x111821, 0x18202A, 0x1D242C, 0x151C24, 0x20262E, 0x121619]
            let phase = Float(index) / Float(count)
            let xRange: CGFloat = isForeground ? 5.7 : (isFar ? 7.2 : 6.4)
            let spinDirection: Float = index.isMultiple(of: 2) ? 1 : -1
            let spinY = spinDirection * Float.pi * Float(1.25 + random(&state) * 0.55)

            specs.append(FloatingBookSpec(
                x: Float(-(xRange / 2) + random(&state) * xRange),
                y: loopBottomY + phase * loopDistance,
                z: z,
                scale: scale,
                pitch: Float(-0.65 + random(&state) * 1.05),
                yaw: Float(-0.85 + random(&state) * 1.7),
                roll: Float(-0.55 + random(&state) * 1.1),
                spinX: Float(-0.45 + random(&state) * 0.9),
                spinY: spinY,
                spinZ: Float(-0.35 + random(&state) * 0.7),
                coverHex: palette[index % palette.count],
                seed: index,
                isInteractive: !isFar,
                driftX: Float(-0.18 + random(&state) * 0.36),
                phase: phase,
                loopBottomY: loopBottomY,
                loopDistance: loopDistance,
                riseDuration: Double(34 + random(&state) * 16),
                rotationDuration: Double(22 + random(&state) * 14)
            ))
        }

        return specs
    }

    private static func makeBookNode(coverHex: UInt32, seed: Int) -> SCNNode {
        let root = SCNNode()
        let coverColor = UIColor(hex: coverHex)
        let spineColor = coverColor.scaledBrightness(0.58)
        let trimColor = coverColor.scaledBrightness(0.42)
        let pageColor = UIColor(red: 0.68, green: 0.64, blue: 0.54, alpha: 1)

        _ = seed
        let coverMaterial = material(
            diffuse: coverColor.scaledBrightness(0.72),
            roughness: 1,
            diffuseIntensity: 0.4,
            specularIntensity: 0,
            multiply: UIColor(white: 0.62, alpha: 1)
        )
        let spineMaterial = material(
            diffuse: spineColor.scaledBrightness(0.7),
            roughness: 1,
            diffuseIntensity: 0.38,
            specularIntensity: 0,
            multiply: UIColor(white: 0.58, alpha: 1)
        )
        let trimMaterial = material(
            diffuse: trimColor.scaledBrightness(0.7),
            roughness: 0.98,
            diffuseIntensity: 0.42,
            specularIntensity: 0
        )
        let pageMaterial = material(diffuse: pageColor, roughness: 0.82, specularIntensity: 0.08)
        let pageSideMaterial = material(diffuse: pageColor.scaledBrightness(0.82), roughness: 0.84, specularIntensity: 0.06)

        let pages = boxNode(
            width: 1.46,
            height: 2.18,
            length: 0.3,
            chamferRadius: 0.025,
            materials: [pageSideMaterial, pageMaterial, pageSideMaterial, pageSideMaterial, pageMaterial, pageMaterial]
        )
        pages.position = SCNVector3(0.09, -0.02, 0)
        root.addChildNode(pages)

        let frontCover = boxNode(
            width: 1.74,
            height: 2.54,
            length: 0.055,
            chamferRadius: 0.035,
            materials: [coverMaterial]
        )
        frontCover.position = SCNVector3(0, 0, 0.19)
        root.addChildNode(frontCover)

        let backCover = boxNode(
            width: 1.74,
            height: 2.54,
            length: 0.055,
            chamferRadius: 0.035,
            materials: [coverMaterial]
        )
        backCover.position = SCNVector3(0, 0, -0.19)
        root.addChildNode(backCover)

        let spine = boxNode(
            width: 0.24,
            height: 2.56,
            length: 0.43,
            chamferRadius: 0.07,
            materials: [spineMaterial]
        )
        spine.position = SCNVector3(-0.81, 0, 0)
        root.addChildNode(spine)

        let foreEdge = boxNode(
            width: 0.045,
            height: 2.17,
            length: 0.27,
            chamferRadius: 0.018,
            materials: [pageMaterial]
        )
        foreEdge.position = SCNVector3(0.83, -0.02, 0)
        root.addChildNode(foreEdge)

        let groove = boxNode(width: 0.026, height: 2.26, length: 0.016, chamferRadius: 0.008, materials: [trimMaterial])
        groove.position = SCNVector3(-0.61, 0, 0.222)
        root.addChildNode(groove)

        let lowerLip = boxNode(width: 1.55, height: 0.026, length: 0.015, chamferRadius: 0.006, materials: [trimMaterial])
        lowerLip.position = SCNVector3(0.03, -1.16, 0.222)
        root.addChildNode(lowerLip)

        let upperLip = boxNode(width: 1.55, height: 0.02, length: 0.014, chamferRadius: 0.006, materials: [trimMaterial])
        upperLip.position = SCNVector3(0.03, 1.16, 0.222)
        root.addChildNode(upperLip)

        return root
    }

    private static func boxNode(
        width: CGFloat,
        height: CGFloat,
        length: CGFloat,
        chamferRadius: CGFloat,
        materials: [SCNMaterial]
    ) -> SCNNode {
        let geometry = SCNBox(
            width: width,
            height: height,
            length: length,
            chamferRadius: chamferRadius
        )
        geometry.materials = materials
        let node = SCNNode(geometry: geometry)
        node.castsShadow = true
        return node
    }

    private static func addMotion(to node: SCNNode, spec: FloatingBookSpec) {
        let startX = spec.x
        let rise = SCNAction.customAction(duration: spec.riseDuration) { node, elapsed in
            let progress = Float(elapsed / CGFloat(spec.riseDuration))
            let wrapped = (progress + spec.phase).truncatingRemainder(dividingBy: 1)
            node.position.x = startX + spec.driftX * wrapped
            node.position.y = spec.loopBottomY + spec.loopDistance * wrapped
        }

        let rotation = SCNAction.rotateBy(
            x: CGFloat(spec.spinX),
            y: CGFloat(spec.spinY),
            z: CGFloat(spec.spinZ),
            duration: spec.rotationDuration
        )
        rotation.timingMode = .linear

        node.runAction(.repeatForever(rise), forKey: "floating-rise")
        node.runAction(.repeatForever(rotation), forKey: "floating-rotation")
    }

    private static func material(
        diffuse: Any,
        roughness: CGFloat,
        diffuseIntensity: CGFloat = 1,
        specularIntensity: CGFloat = 0.12,
        multiply: Any? = nil
    ) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = diffuse
        material.diffuse.intensity = diffuseIntensity
        if let multiply {
            material.multiply.contents = multiply
        }
        material.roughness.contents = roughness
        material.metalness.contents = 0
        material.specular.contents = UIColor.white
        material.specular.intensity = specularIntensity
        material.lightingModel = .physicallyBased
        return material
    }

    private static func random(_ state: inout UInt64) -> CGFloat {
        state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
        let value = Double((state >> 11) & 0x1F_FFFF) / Double(0x1F_FFFF)
        return CGFloat(value)
    }
}

private struct FloatingBookSpec: Sendable {
    let x: Float
    let y: Float
    let z: Float
    let scale: Float
    let pitch: Float
    let yaw: Float
    let roll: Float
    let spinX: Float
    let spinY: Float
    let spinZ: Float
    let coverHex: UInt32
    let seed: Int
    let isInteractive: Bool
    let driftX: Float
    let phase: Float
    let loopBottomY: Float
    let loopDistance: Float
    let riseDuration: TimeInterval
    let rotationDuration: TimeInterval
}

private extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    func scaledBrightness(_ scale: CGFloat) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return UIColor(
            red: min(max(red * scale, 0), 1),
            green: min(max(green * scale, 0), 1),
            blue: min(max(blue * scale, 0), 1),
            alpha: alpha
        )
    }
}

private struct ImportToast: View {
    let phase: BackgroundArticleImporter.Phase

    var body: some View {
        if case .idle = phase {
            EmptyView()
        } else {
            pill
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    @ViewBuilder
    private var pill: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .importing(let progress):
            pillBody(label: "Saving article…", progress: progress) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.55)
                    .tint(.white.opacity(0.9))
                    .frame(width: 16, height: 16)
            }
        case .success:
            pillBody(label: "Article saved", progress: nil) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 16, height: 16)
            }
        case .failure:
            pillBody(label: "Couldn't import (see alert)", progress: nil) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 16, height: 16)
            }
        }
    }

    private func pillBody<Leading: View>(
        label: String,
        progress: Double?,
        @ViewBuilder leading: () -> Leading
    ) -> some View {
        HStack(spacing: 10) {
            leading()
            VStack(alignment: .leading, spacing: progress == nil ? 0 : 5) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .fixedSize()
                if let progress {
                    Capsule()
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 140, height: 3)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.9))
                                .frame(width: 140 * progress, height: 3)
                                .animation(.easeOut(duration: 0.2), value: progress)
                        }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .darkFrosted(in: Capsule())
        .overlay(
            Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
    }
}

private struct ChapterListView: View {
    let book: EpubBook

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            List {
                if let data = book.coverImageData, let uiImage = UIImage(data: data) {
                    HStack {
                        Spacer()
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
                        Spacer()
                    }
                    .listRowBackground(Color.black)
                    .listRowSeparatorTint(.clear)
                    .padding(.vertical, 8)
                }

                ForEach(Array(book.chapters.enumerated()), id: \.element.id) { index, chapter in
                    NavigationLink {
                        ScrollTextView(
                            chapters: book.chapters,
                            startingIndex: index,
                            bookID: book.id,
                            bookTitle: book.title,
                            bookAuthor: book.author,
                            bookDescription: book.description
                        )
                            .toolbar(.hidden, for: .navigationBar)
                            .navigationBarBackButtonHidden(true)
                    } label: {
                        ChapterRow(title: chapter.title, depth: chapter.depth)
                    }
                    .listRowBackground(Color.black)
                    .listRowSeparatorTint(.white.opacity(0.06))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.black)
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .darkNavigationBar()
    }
}

private struct ChapterRow: View {
    let title: String
    let depth: Int

    private var leadingPadding: CGFloat {
        CGFloat(min(depth, 3)) * 16
    }

    private var opacity: Double {
        switch depth {
        case 0: return 1.0
        case 1: return 0.75
        default: return 0.55
        }
    }

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .regular))
            .foregroundColor(.white.opacity(opacity))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, leadingPadding)
            .padding(.vertical, 8)
    }
}

@MainActor
final class EpubLibrary: ObservableObject {
    @Published private(set) var books: [EpubBook] = []
    @Published private(set) var isLoading: Bool = false

    let booksDirectory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("epubs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func seedDefaultEpubs() async {
        let dest = booksDirectory.appendingPathComponent("UXTeamofOne.epub")
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dest.path) else { return }
        guard let bundleURL = Bundle.main.url(forResource: "UXTeamofOne", withExtension: "epub") else { return }
        do {
            try fm.copyItem(at: bundleURL, to: dest)
            await loadFromDisk()
        } catch {}
    }

    func loadFromDisk() async {
        isLoading = true
        defer { isLoading = false }
        let dir = booksDirectory
        let parsed: [EpubBook] = await Task.detached {
            let fm = FileManager.default
            guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                return []
            }
            let epubs = urls.filter { $0.pathExtension.lowercased() == "epub" }
            var result: [EpubBook] = []
            for url in epubs {
                if let book = try? EpubParser.parse(fileURL: url) {
                    result.append(book)
                }
            }
            return result
        }.value
        books = parsed.sorted(by: sortedByTitle)
    }

    func delete(_ book: EpubBook) {
        try? FileManager.default.removeItem(at: book.fileURL)
        books.removeAll { $0.id == book.id }
    }

    func importFile(at sourceURL: URL) async throws -> EpubBook {
        let dir = booksDirectory
        let dest = dir.appendingPathComponent(sourceURL.lastPathComponent)

        let book: EpubBook = try await Task.detached {
            let fm = FileManager.default
            let tempURL = dir.appendingPathComponent(".import-\(UUID().uuidString)-\(sourceURL.lastPathComponent)")
            defer { try? fm.removeItem(at: tempURL) }

            let didStart = sourceURL.startAccessingSecurityScopedResource()
            defer { if didStart { sourceURL.stopAccessingSecurityScopedResource() } }

            try fm.copyItem(at: sourceURL, to: tempURL)
            _ = try EpubParser.parse(fileURL: tempURL)

            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: dest)
            }
            return try EpubParser.parse(fileURL: dest)
        }.value

        if let idx = books.firstIndex(where: { $0.id == book.id }) {
            books[idx] = book
        } else {
            books.append(book)
            books.sort(by: sortedByTitle)
        }
        return book
    }

    private let sortedByTitle: (EpubBook, EpubBook) -> Bool = { $0.title.lowercased() < $1.title.lowercased() }
}
