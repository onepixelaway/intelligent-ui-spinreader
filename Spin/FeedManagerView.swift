import SwiftUI

struct FeedManagerView: View {
    @ObservedObject var store: FeedStore
    @Environment(\.dismiss) private var dismiss

    @State private var draftURL: String = ""
    @State private var isAdding: Bool = false
    @State private var addError: String?

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
        Group {
            if store.feeds.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 28))
                        .foregroundColor(.gray.opacity(0.5))
                    Text("No feeds yet")
                        .font(.system(size: 15))
                        .foregroundColor(.gray.opacity(0.7))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(store.feeds) { feed in
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
                    .onDelete { indexSet in
                        store.removeFeeds(at: indexSet)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.black)
            }
        }
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
}
