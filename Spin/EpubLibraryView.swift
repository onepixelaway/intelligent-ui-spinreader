import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

struct EpubLibraryView: View {
    @StateObject private var library = EpubLibrary()
    @StateObject private var articleStore = WebArticleStore()
    @State private var showImporter = false
    @State private var showBrowser = false
    @State private var showPasteText = false
    @State private var errorMessage: String?
    @State private var isImportingArticle = false
    @State private var isJiggling = false
    @State private var bookPendingDeletion: EpubBook?
    @State private var navigationPath = NavigationPath()

    private let columns = [
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20)
    ]

    private enum LibraryItem: Identifiable, Hashable {
        case book(EpubBook)
        case article(WebArticle)

        var id: String {
            switch self {
            case .book(let b): return "book:\(b.id)"
            case .article(let a): return "article:\(a.id.uuidString)"
            }
        }

        var sortKey: String {
            switch self {
            case .book(let b): return b.title.lowercased()
            case .article(let a): return a.title.lowercased()
            }
        }
    }

    private static func articleBookID(_ article: WebArticle) -> String {
        "article:\(article.id.uuidString)"
    }

    private var libraryItems: [LibraryItem] {
        let books = library.books.map(LibraryItem.book)
        let articles = articleStore.articles.map(LibraryItem.article)
        return (books + articles).sorted { $0.sortKey < $1.sortKey }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                Color.black.ignoresSafeArea()

                if library.isLoading && libraryItems.isEmpty {
                    ProgressView()
                        .tint(.white.opacity(0.6))
                } else if libraryItems.isEmpty {
                    emptyState
                } else {
                    bookGrid
                        .overlay(alignment: .bottomTrailing) {
                            if !isJiggling {
                                addMenu {
                                    Image(systemName: "plus")
                                        .font(.system(size: 24, weight: .semibold))
                                        .foregroundColor(.black)
                                        .frame(width: 56, height: 56)
                                        .background(Color.white)
                                        .clipShape(Circle())
                                        .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
                                }
                                .padding(.bottom, 32)
                                .padding(.trailing, 24)
                                .transition(.opacity)
                            }
                        }
                }
            }
            .navigationTitle("Books")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !isJiggling {
                        NavigationLink {
                            SettingsView()
                        } label: {
                            Image(systemName: "gearshape")
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isJiggling {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { isJiggling = false }
                        } label: {
                            Text("Done")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                        }
                    } else {
                        addMenu {
                            Image(systemName: "plus")
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                }
            }
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
                bookPendingDeletion.map { "Delete \"\($0.title)\"?" } ?? "Delete book?",
                isPresented: deleteAlertBinding,
                presenting: bookPendingDeletion
            ) { book in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    library.delete(book)
                    if libraryItems.isEmpty {
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
        }
    }

    @ViewBuilder
    private func addMenu<TriggerLabel: View>(@ViewBuilder label: () -> TriggerLabel) -> some View {
        Menu {
            Button {
                showBrowser = true
            } label: {
                Label("Save from the web", systemImage: "globe")
            }
            Button {
                showPasteText = true
            } label: {
                Label("Paste Text", systemImage: "doc.on.clipboard")
            }
            Button {
                showImporter = true
            } label: {
                Label("Import ePub file", systemImage: "doc")
            }
        } label: {
            label()
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { bookPendingDeletion != nil },
            set: { if !$0 { bookPendingDeletion = nil } }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.gray.opacity(0.4))
            Text("Build your library")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
            Text("Save articles from the web or import an .epub file to start reading.")
                .font(.system(size: 14))
                .foregroundColor(.gray.opacity(0.6))
                .multilineTextAlignment(.center)

            addMenu {
                Text("Add a book")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.white)
                    .clipShape(Capsule())
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 32)
    }

    private var bookGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(Array(libraryItems.enumerated()), id: \.element.id) { index, item in
                    gridCell(item: item, index: index)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
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

    @ViewBuilder
    private func gridCell(item: LibraryItem, index: Int) -> some View {
        ZStack(alignment: .topLeading) {
            cellContent(for: item)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isJiggling {
                        navigate(to: item)
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
                deleteButton(for: item)
                    .offset(x: -8, y: -8)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .modifier(JiggleModifier(isJiggling: isJiggling, index: index))
    }

    @ViewBuilder
    private func cellContent(for item: LibraryItem) -> some View {
        switch item {
        case .book(let book):
            BookCard(book: book)
        case .article(let article):
            ArticleCard(article: article)
        }
    }

    private func navigate(to item: LibraryItem) {
        switch item {
        case .book(let book):
            navigationPath.append(book)
        case .article(let article):
            navigationPath.append(article)
        }
    }

    private func deleteButton(for item: LibraryItem) -> some View {
        Button {
            switch item {
            case .book(let book):
                bookPendingDeletion = book
            case .article(let article):
                articleStore.delete(article)
                if libraryItems.isEmpty {
                    withAnimation(.easeOut(duration: 0.2)) { isJiggling = false }
                }
            }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.black))
                .overlay(
                    Circle().stroke(Color.white.opacity(0.4), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
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
        let items = MarkdownParser.parse(text: body, title: resolvedTitle)
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

private struct BookCard: View {
    let book: EpubBook

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            coverImage
                .frame(maxWidth: .infinity)
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)

            Text(book.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if !book.author.isEmpty {
                Text(book.author)
                    .font(.system(size: 11))
                    .foregroundColor(.gray.opacity(0.6))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var coverImage: some View {
        if let data = book.coverImageData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            PlaceholderCover(title: book.title, author: book.author)
        }
    }
}

private struct ArticleCard: View {
    let article: WebArticle
    @State private var coverImage: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cover
                .frame(maxWidth: .infinity)
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)

            Text(article.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(.gray.opacity(0.6))
                .lineLimit(1)
        }
        .task(id: article.coverImagePath) {
            await loadCover()
        }
    }

    private var subtitle: String {
        if !article.author.isEmpty { return article.author }
        if let host = article.sourceURL?.host { return host }
        return article.sourceURL == nil ? "Pasted" : "Article"
    }

    @ViewBuilder
    private var cover: some View {
        if let coverImage {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: coverImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                badge
                    .padding(8)
            }
        } else {
            placeholderCover
        }
    }

    private var placeholderCover: some View {
        GeometryReader { geo in
            let colors = deterministicGradient(for: article.title + (article.sourceURL?.host ?? ""))
            ZStack {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)

                VStack(spacing: 10) {
                    Image(systemName: article.sourceURL == nil ? "doc.on.clipboard" : "globe")
                        .font(.system(size: min(geo.size.width * 0.28, 48), weight: .light))
                        .foregroundColor(.white.opacity(0.85))
                    Text(article.title)
                        .font(.system(size: min(geo.size.width * 0.09, 14), weight: .semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 12)
                }

                badge
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    private var badge: some View {
        Text(article.sourceURL == nil ? "Pasted" : "Article")
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundColor(.white.opacity(0.9))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.45)))
    }

    private func loadCover() async {
        guard let url = article.coverImageURL else {
            coverImage = nil
            return
        }
        let data: Data? = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url)
        }.value
        guard let data, let image = UIImage(data: data) else {
            coverImage = nil
            return
        }
        coverImage = image
    }
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
