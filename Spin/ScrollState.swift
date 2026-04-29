import SwiftUI

@MainActor
final class ScrollState: ObservableObject {
    @Published var currentPage: Int = 0
    @Published private var transientOffset: Double?

    // Page-start y offsets in scroll-content space; first is always 0.
    private(set) var pageStarts: [Double] = [0]

    var totalPages: Int { pageStarts.count }

    var offset: Double {
        -effectiveStartY
    }

    var isAtBottom: Bool {
        currentPage >= totalPages - 1
    }

    var isAtTop: Bool {
        currentPage <= 0
    }

    private var effectiveStartY: Double {
        if let transientOffset {
            return transientOffset
        }
        guard currentPage < pageStarts.count else { return pageStarts.last ?? 0 }
        return pageStarts[currentPage]
    }

    func setPageStarts(_ starts: [Double]) {
        let normalized = normalize(starts)
        guard normalized != pageStarts else { return }
        let oldCurrentY = effectiveStartY
        pageStarts = normalized
        // Re-anchor currentPage to the page containing the old y-position so font/margin changes
        // preserve the reader's visible line rather than resetting to page 0.
        currentPage = pageContaining(y: oldCurrentY)
        if transientOffset != nil {
            transientOffset = min(max(0, oldCurrentY), pageStarts.last ?? oldCurrentY)
        }
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
        transientOffset = nil
        currentPage += 1
    }

    func goToPage(_ page: Int) {
        transientOffset = nil
        guard totalPages > 0 else {
            currentPage = 0
            return
        }
        currentPage = min(max(0, page), totalPages - 1)
    }

    func goToContentOffset(_ y: Double) {
        let clamped = min(max(0, y), pageStarts.last ?? y)
        transientOffset = clamped
        currentPage = pageContaining(y: clamped)
    }

    func goToPreviousPage() {
        guard currentPage > 0 else { return }
        transientOffset = nil
        currentPage -= 1
    }

    func resetToTop() {
        transientOffset = nil
        currentPage = 0
    }
}
