import SwiftUI

@MainActor
final class ScrollState: ObservableObject {
    @Published var currentPage: Int = 0

    // Page-start y offsets in scroll-content space; first is always 0.
    private(set) var pageStarts: [Double] = [0]

    var totalPages: Int { pageStarts.count }

    var offset: Double {
        guard currentPage < pageStarts.count else { return -(pageStarts.last ?? 0) }
        return -pageStarts[currentPage]
    }

    var isAtBottom: Bool {
        currentPage >= totalPages - 1
    }

    var isAtTop: Bool {
        currentPage <= 0
    }

    func setPageStarts(_ starts: [Double]) {
        let normalized = normalize(starts)
        guard normalized != pageStarts else { return }
        let oldCurrentY = pageStarts.indices.contains(currentPage) ? pageStarts[currentPage] : 0
        pageStarts = normalized
        // Re-anchor currentPage to the page containing the old y-position so font/margin changes
        // preserve the reader's visible line rather than resetting to page 0.
        currentPage = pageContaining(y: oldCurrentY)
    }

    private func normalize(_ starts: [Double]) -> [Double] {
        var out: [Double] = []
        for s in starts.sorted() {
            let clamped = max(0, s)
            if let last = out.last, clamped - last < 1 { continue }
            out.append(clamped)
        }
        if out.first != 0 { out.insert(0, at: 0) }
        return out
    }

    private func pageContaining(y: Double) -> Int {
        guard !pageStarts.isEmpty else { return 0 }
        var best = 0
        for (i, start) in pageStarts.enumerated() {
            if start <= y + 0.5 { best = i } else { break }
        }
        return min(best, pageStarts.count - 1)
    }

    func goToNextPage() {
        guard currentPage < totalPages - 1 else { return }
        currentPage += 1
    }

    func goToPreviousPage() {
        guard currentPage > 0 else { return }
        currentPage -= 1
    }

    func resetToTop() {
        currentPage = 0
    }
}
