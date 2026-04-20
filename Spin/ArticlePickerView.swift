import SwiftUI
import UIKit

struct ArticlePickerView: View {
    @StateObject private var store = FeedStore()
    @State private var showingFeedManager = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if store.feeds.isEmpty {
                    emptyState
                } else {
                    articleList
                }
            }
            .navigationTitle("Spin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingFeedManager = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sheet(isPresented: $showingFeedManager) {
                FeedManagerView(store: store)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if !store.feeds.isEmpty, store.articlesByFeed.isEmpty {
                await store.refresh()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "newspaper")
                .font(.system(size: 36, weight: .light))
                .foregroundColor(.gray.opacity(0.5))
            Text("No feeds yet")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
            Text("Add an RSS feed URL to begin reading.")
                .font(.system(size: 14))
                .foregroundColor(.gray.opacity(0.7))

            Button {
                showingFeedManager = true
            } label: {
                Text("Add Feed")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.white)
                    .clipShape(Capsule())
            }
            .padding(.top, 8)

            NavigationLink {
                ScrollTextView()
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationBarBackButtonHidden(true)
            } label: {
                Text("Read demo article")
                    .font(.system(size: 13))
                    .foregroundColor(.gray.opacity(0.7))
                    .underline()
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 32)
    }

    private var articleList: some View {
        List {
            ForEach(store.feeds) { feed in
                let articles = store.articlesByFeed[feed.id] ?? []
                Section {
                    if articles.isEmpty {
                        Text("No articles")
                            .font(.system(size: 13))
                            .foregroundColor(.gray.opacity(0.6))
                            .listRowBackground(Color.black)
                    } else {
                        ForEach(articles) { article in
                            NavigationLink {
                                ScrollTextView(article: article)
                                    .toolbar(.hidden, for: .navigationBar)
                                    .navigationBarBackButtonHidden(true)
                            } label: {
                                ArticleRow(article: article)
                            }
                            .listRowBackground(Color.black)
                            .listRowSeparatorTint(.white.opacity(0.06))
                        }
                    }
                } header: {
                    HStack(spacing: 10) {
                        FaviconView(feedURL: feed.url)
                        Text(feed.title.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(1.2)
                            .foregroundColor(.gray.opacity(0.55))
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black)
                    .listRowInsets(EdgeInsets())
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .refreshable {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            await store.refresh()
        }
    }
}

private struct ArticleRow: View {
    let article: Article

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(article.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                if let meta = metaLine {
                    Text(meta)
                        .font(.system(size: 12))
                        .foregroundColor(.gray.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let thumbnail = article.heroImageURL {
                ArticleThumbnail(url: thumbnail)
            }
        }
        .padding(.vertical, 6)
    }

    private var metaLine: String? {
        var parts: [String] = []
        if let author = article.author, !author.isEmpty { parts.append(author) }
        if let date = article.publishedDate {
            parts.append(relativeTimeString(from: date))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct ArticleThumbnail: View {
    let url: URL
    var size: CGFloat = 52

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.15))) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            default:
                Color.white.opacity(0.04)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

nonisolated(unsafe) private let relativeTimeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
}()

private func relativeTimeString(from date: Date) -> String {
    relativeTimeFormatter.localizedString(for: date, relativeTo: Date())
}

private struct FaviconView: View {
    let feedURL: URL
    var size: CGFloat = 26

    var body: some View {
        AsyncImage(url: Self.faviconURL(for: feedURL), transaction: Transaction(animation: .easeIn(duration: 0.15))) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            default:
                Image(systemName: "globe")
                    .font(.system(size: size * 0.55, weight: .regular))
                    .foregroundColor(.gray.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: size, height: size)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private static func faviconURL(for url: URL) -> URL? {
        guard let host = url.host, !host.isEmpty else { return nil }
        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=128")
    }
}

#Preview {
    ArticlePickerView()
}
