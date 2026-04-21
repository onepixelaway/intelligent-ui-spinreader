import SwiftUI

struct HighlightsListView: View {
    let contentIDs: [String]
    @Environment(HighlightStore.self) private var highlightStore
    @Environment(\.dismiss) private var dismiss

    private var highlights: [Highlight] {
        contentIDs.flatMap { highlightStore.highlights(for: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Highlights")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            if highlights.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "highlighter")
                        .font(.system(size: 32))
                        .foregroundColor(.white.opacity(0.2))
                    Text("No highlights yet")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(highlights) { highlight in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(highlight.text)
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.85))
                                .lineLimit(3)
                            Text(highlight.createdAt, style: .relative)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.4))
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Color.white.opacity(0.06))
                        .listRowSeparatorTint(.white.opacity(0.1))
                    }
                    .onDelete { indexSet in
                        let ids = Set(indexSet.map { highlights[$0].id })
                        highlightStore.removeBatch(ids: ids)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.black)
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}
