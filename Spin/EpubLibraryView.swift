import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct EpubLibraryView: View {
    @StateObject private var library = EpubLibrary()
    @State private var showImporter = false
    @State private var errorMessage: String?

    private let columns = [
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if library.isLoading && library.books.isEmpty {
                    ProgressView()
                        .tint(.white.opacity(0.6))
                } else if library.books.isEmpty {
                    emptyState
                } else {
                    bookGrid
                }
            }
            .navigationTitle("Books")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.epub],
                allowsMultipleSelection: true
            ) { result in
                Task { await handleImport(result: result) }
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
        }
        .preferredColorScheme(.dark)
        .task {
            await library.seedDefaultEpubs()
            if library.books.isEmpty {
                await library.loadFromDisk()
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.gray.opacity(0.4))
            Text("Add your first book")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
            Text("Import an .epub file to start reading.")
                .font(.system(size: 14))
                .foregroundColor(.gray.opacity(0.6))
                .multilineTextAlignment(.center)

            Button {
                showImporter = true
            } label: {
                Text("Import ePub")
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
                ForEach(library.books) { book in
                    NavigationLink {
                        ChapterListView(book: book)
                    } label: {
                        BookCard(book: book)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
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
                    Spacer()
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
                    Spacer()
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
            Color(hue: hue1, saturation: 0.5, brightness: 0.35),
            Color(hue: hue2, saturation: 0.6, brightness: 0.25)
        ]
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
                        ScrollTextView(chapters: book.chapters, startingIndex: index)
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
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
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

    private var booksDirectory: URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("epubs", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

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
        books = parsed.sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    func importFile(at sourceURL: URL) async throws -> EpubBook {
        let dir = booksDirectory
        let dest = dir.appendingPathComponent(sourceURL.lastPathComponent)

        let book: EpubBook = try await Task.detached {
            let fm = FileManager.default
            if fm.fileExists(atPath: dest.path) {
                try? fm.removeItem(at: dest)
            }
            let didStart = sourceURL.startAccessingSecurityScopedResource()
            defer { if didStart { sourceURL.stopAccessingSecurityScopedResource() } }
            try fm.copyItem(at: sourceURL, to: dest)
            return try EpubParser.parse(fileURL: dest)
        }.value

        if let idx = books.firstIndex(where: { $0.id == book.id }) {
            books[idx] = book
        } else {
            books.append(book)
            books.sort { $0.title.lowercased() < $1.title.lowercased() }
        }
        return book
    }

    func delete(at offsets: IndexSet) {
        let toDelete = offsets.map { books[$0] }
        for book in toDelete {
            try? FileManager.default.removeItem(at: book.fileURL)
        }
        books.remove(atOffsets: offsets)
    }
}
