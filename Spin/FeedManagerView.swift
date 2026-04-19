import SwiftUI

struct SuggestedFeed: Identifiable, Hashable {
    let name: String
    let category: String
    let url: String
    var id: String { url }
}

struct FeedManagerView: View {
    @ObservedObject var store: FeedStore
    @Environment(\.dismiss) private var dismiss

    @State private var draftURL: String = ""
    @State private var isAdding: Bool = false
    @State private var addError: String?
    @State private var addingSuggestionID: String?

    private static let suggestedFeeds: [SuggestedFeed] = [
        .init(name: "404 Media", category: "Tech journalism", url: "https://www.404media.co/rss/"),
        .init(name: "Aeon", category: "Essays/ideas", url: "https://aeon.co/feed.rss"),
        .init(name: "Quanta Magazine", category: "Science", url: "https://api.quantamagazine.org/feed/"),
        .init(name: "Low-tech Magazine", category: "Sustainability", url: "https://solar.lowtechmagazine.com/feeds/all-en.atom.xml"),
        .init(name: "The Conversation (US)", category: "Academic journalism", url: "https://theconversation.com/us/articles.atom"),
        .init(name: "Krebs on Security", category: "Security", url: "https://krebsonsecurity.com/feed/"),
        .init(name: "Schneier on Security", category: "Security", url: "https://www.schneier.com/feed/atom/"),
        .init(name: "Pluralistic (Cory Doctorow)", category: "Tech/policy", url: "https://pluralistic.net/feed/"),
        .init(name: "The Marginalian", category: "Culture/ideas", url: "https://www.themarginalian.org/feed/"),
        .init(name: "Kottke.org", category: "Culture", url: "https://kottke.org/index.xml"),
        .init(name: "Daring Fireball", category: "Apple/tech", url: "https://daringfireball.net/feeds/main"),
        .init(name: "Astral Codex Ten", category: "Essays", url: "https://www.astralcodexten.com/feed"),
        .init(name: "Wait But Why", category: "Longform", url: "https://waitbutwhy.com/feed"),
        .init(name: "Simon Willison's Weblog", category: "Tech/AI", url: "https://simonwillison.net/atom/everything/"),
        .init(name: "Julia Evans", category: "Programming", url: "https://jvns.ca/atom.xml"),
    ]

    private var trimmedURL: String {
        draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    addRow
                    if let addError {
                        Text(addError)
                            .font(.system(size: 12))
                            .foregroundColor(Color(red: 1.0, green: 0.4, blue: 0.4))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 10)
                    }
                    feedList
                }
            }
            .navigationTitle("Feeds")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.white)
                }
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .presentationBackground(Color.black)
    }

    private var addRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "link")
                .foregroundColor(.gray.opacity(0.7))
                .font(.system(size: 14))

            TextField(
                "",
                text: $draftURL,
                prompt: Text("https://example.com/feed.xml")
                    .foregroundColor(.gray.opacity(0.5))
            )
            .textFieldStyle(.plain)
            .foregroundColor(.white)
            .tint(.white)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .submitLabel(.go)
            .onSubmit { Task { await submit() } }

            if isAdding {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.7))
            } else {
                Button {
                    Task { await submit() }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(trimmedURL.isEmpty ? .gray.opacity(0.4) : .white)
                }
                .disabled(trimmedURL.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(.white.opacity(0.08))
        }
    }

    private var feedList: some View {
        List {
            if !store.feeds.isEmpty {
                Section {
                    ForEach(store.feeds) { feed in
                        feedRow(feed)
                    }
                    .onDelete { indexSet in
                        store.removeFeeds(at: indexSet)
                    }
                } header: {
                    sectionHeader("Your Feeds")
                }
            }

            Section {
                ForEach(Self.suggestedFeeds) { suggestion in
                    suggestionRow(suggestion)
                }
            } header: {
                sectionHeader("Suggested")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.black)
    }

    private func feedRow(_ feed: Feed) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(feed.title)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
            Text(feed.url.absoluteString)
                .font(.system(size: 12))
                .foregroundColor(.gray.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 6)
        .listRowBackground(Color.black)
        .listRowSeparatorTint(.white.opacity(0.06))
    }

    private func suggestionRow(_ suggestion: SuggestedFeed) -> some View {
        let isAdded = isAlreadyAdded(suggestion)
        let isLoading = addingSuggestionID == suggestion.id

        return Button {
            guard !isAdded, !isLoading else { return }
            Task { await addSuggestion(suggestion) }
        } label: {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Text(suggestion.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    categoryPill(suggestion.category)
                }

                Spacer(minLength: 8)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.7))
                } else if isAdded {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.gray.opacity(0.6))
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .opacity(isAdded ? 0.4 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isAdded || isLoading)
        .listRowBackground(Color.black)
        .listRowSeparatorTint(.white.opacity(0.06))
    }

    private func categoryPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(0.65))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.08))
            )
            .lineLimit(1)
            .fixedSize()
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.gray.opacity(0.6))
            .textCase(nil)
            .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 6, trailing: 20))
    }

    private func isAlreadyAdded(_ suggestion: SuggestedFeed) -> Bool {
        guard let url = URL(string: suggestion.url) else { return false }
        return store.feeds.contains(where: { $0.url == url })
    }

    private func submit() async {
        let raw = trimmedURL
        guard !raw.isEmpty else { return }
        isAdding = true
        addError = nil
        do {
            try await store.addFeed(rawURL: raw)
            draftURL = ""
        } catch {
            addError = error.localizedDescription
        }
        isAdding = false
    }

    private func addSuggestion(_ suggestion: SuggestedFeed) async {
        addingSuggestionID = suggestion.id
        addError = nil
        do {
            try await store.addFeed(rawURL: suggestion.url)
        } catch {
            addError = "Couldn’t add \(suggestion.name): \(error.localizedDescription)"
        }
        addingSuggestionID = nil
    }
}
