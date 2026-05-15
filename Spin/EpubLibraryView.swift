import SwiftUI
import UIKit
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
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    libraryHeader
                    addNewSection
                    booksCarouselSection(screenWidth: screenWidth)
                    articlesStackSection
                }
                .padding(.top, 24)
                .padding(.bottom, 32)
                .frame(width: screenWidth, alignment: .leading)
            }
            .scrollIndicators(.hidden)
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
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .regular))
                    .symbolRenderingMode(.monochrome)
                    .foregroundColor(.white)
                    .frame(height: 34)

                Spacer(minLength: 4)

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
